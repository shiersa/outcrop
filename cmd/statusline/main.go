// claude-statusline —— 按 provider 分派的 Claude Code statusline。
//
// 相比 Python 版的三处实质改进：
//  1. transcript 增量扫描。缓存 (size, mtime) 与累计值，只解析新增字节。
//     长会话下这是数量级的差别，而不是换语言带来的常数倍。
//  2. 单个静态二进制。没有解释器版本、PATH、虚拟环境的问题 ——
//     同一台机器上 python3 解析到不同版本这种事不会再发生。
//  3. 永不 panic。statusline 崩了整行就没了，顶层 recover 兜底。
//
// 只用标准库，go build 不需要联网拉依赖。
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unsafe"
)

// ---------------------------------------------------------------------------
// 路径与常量
// ---------------------------------------------------------------------------

var (
	home     = must(os.UserHomeDir())
	baseDir  = filepath.Join(configHome(), "claude-statusline")
	cacheDir = filepath.Join(baseDir, "cache")

	pricingPath  = filepath.Join(baseDir, "pricing.json")
	ctxWinPath   = filepath.Join(baseDir, "context_windows.json")
	displayPath  = filepath.Join(baseDir, "display.json")
	glmCfgPath   = filepath.Join(baseDir, "glm.json")
	lastInput    = filepath.Join(cacheDir, "last-input.json")
	litellmCache = filepath.Join(cacheDir, "litellm-prices.json")
)

const (
	quotaTTL   = 5 * time.Minute
	netTimeout = 4 * time.Second

	// LiteLLM 社区维护的标准价目表（MIT），按每 token 计价。
	// 我们的 pricing.json 用每 1M token，拉取后 ×1e6 换算。
	litellmURL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
)

// buildVersion 由 scripts/release.sh 用 -ldflags "-X main.buildVersion=<版本>" 注入；
// 现场编译时保持 "dev"。多台机器装了不同版本时，--version 是唯一快速分清的办法。
var buildVersion = "dev"

// 智谱国内站(open.bigmodel.cn)与海外站(api.z.ai)是两套域名，端点路径、鉴权方式、
// 响应字段都可能不同，且没有公开确认过。所以不硬编码 —— 用 --probe-glm 探测出真实
// 情况后写进 glm.json，按 base_url 自动选对应站点，改配置即生效，不用重新编译。
//
// 注意：z.ai 的额度端点路径没有官方来源，是按国内站类推猜的，鉴权方式也未知，
// 所以 --probe-glm 会同时试 raw 和 bearer 两种鉴权。
var glmDefaultEndpoints = map[string]glmEndpoint{
	"bigmodel.cn": {URL: "https://open.bigmodel.cn/api/monitor/usage/quota/limit", AuthScheme: "raw"},
	"z.ai":        {URL: "https://api.z.ai/api/monitor/usage/quota/limit", AuthScheme: "raw"},
}

// glmDefaultFields 是字段命名的兜底候选；每个站点可在 glm.json 里覆盖。
var glmDefaultFields = map[string][]string{
	"used_pct": {"used_pct", "usedPercent", "percent", "usage_rate"},
	"used":     {"used", "used_tokens", "usedTokens"},
	"total":    {"total", "limit", "quota", "total_tokens"},
	"mcp_pct":  {"mcp_used_pct", "mcpPercent", "mcp_usage"},
}

type glmEndpoint struct {
	URL        string              `json:"url"`
	AuthScheme string              `json:"auth_scheme"` // raw | bearer
	Fields     map[string][]string `json:"fields"`
}

type glmConfig struct {
	Endpoints map[string]glmEndpoint `json:"endpoints"`
}

// normalized 补默认：auth 空 → raw，fields 缺项 → glmDefaultFields。
func (e glmEndpoint) normalized() glmEndpoint {
	if e.AuthScheme == "" {
		e.AuthScheme = "raw"
	}
	if e.Fields == nil {
		e.Fields = map[string][]string{}
	}
	for k, v := range glmDefaultFields {
		if _, ok := e.Fields[k]; !ok {
			e.Fields[k] = v
		}
	}
	return e
}

// loadGLMConfig 读 glm.json。新结构是 endpoints 映射；旧的单 endpoint 结构自动迁移。
// 迁移静默进行 —— 本函数在每次渲染都被调，stdout 就是状态栏，不能往里打印；
// 原文件备份成 .bak-<时间戳>，_comment 等顶层键保留。
func loadGLMConfig() glmConfig {
	raw, err := os.ReadFile(glmCfgPath)
	if err != nil {
		return glmConfig{} // 无配置文件，调用方走内置默认
	}
	var probe struct {
		Endpoints json.RawMessage `json:"endpoints"`
		Endpoint  string          `json:"endpoint"`
	}
	if json.Unmarshal(raw, &probe) != nil {
		return glmConfig{}
	}
	if len(probe.Endpoints) > 0 && strings.TrimSpace(string(probe.Endpoints)) != "null" {
		var c glmConfig
		if json.Unmarshal(raw, &c) == nil {
			return c
		}
	}
	if probe.Endpoint != "" {
		return migrateLegacyGLM(raw)
	}
	return glmConfig{}
}

// migrateLegacyGLM 把旧的单 endpoint 结构升级成 endpoints 映射：旧 endpoint 按 URL
// 域名片段归位（保留用户实测的 fields），另一个内置站点补默认；保留 _comment 等顶层键。
func migrateLegacyGLM(raw []byte) glmConfig {
	var top map[string]json.RawMessage
	if json.Unmarshal(raw, &top) != nil {
		top = map[string]json.RawMessage{}
	}
	var leg struct {
		Endpoint   string              `json:"endpoint"`
		AuthScheme string              `json:"auth_scheme"`
		Fields     map[string][]string `json:"fields"`
	}
	_ = json.Unmarshal(raw, &leg)

	siteKey := defaultSiteKeyForURL(leg.Endpoint)
	if leg.AuthScheme == "" {
		leg.AuthScheme = "raw"
	}
	eps := map[string]glmEndpoint{
		siteKey: {URL: leg.Endpoint, AuthScheme: leg.AuthScheme, Fields: leg.Fields},
	}
	for k, v := range glmDefaultEndpoints {
		if _, ok := eps[k]; !ok {
			eps[k] = v
		}
	}

	delete(top, "endpoint")
	delete(top, "auth_scheme")
	delete(top, "fields")
	epBytes, _ := json.MarshalIndent(eps, "", "  ")
	top["endpoints"] = epBytes
	if _, err := backupFile(glmCfgPath); err == nil {
		_ = saveJSON(glmCfgPath, top)
	}
	return glmConfig{Endpoints: eps}
}

// defaultSiteKeyForURL 按 URL 里的域名片段推断归属哪个内置站点（最长命中）；都不含则归国内站。
func defaultSiteKeyForURL(u string) string {
	l := strings.ToLower(u)
	var bestKey string
	bestLen := 0
	for k := range glmDefaultEndpoints {
		kk := strings.ToLower(k)
		if strings.Contains(l, kk) && len(kk) > bestLen {
			bestKey, bestLen = k, len(kk)
		}
	}
	if bestKey != "" {
		return bestKey
	}
	return "bigmodel.cn"
}

// resolveGLMSite 按当前 base_url 选站点：先匹配置里的 endpoints key（最长命中），
// 再退到内置默认。返回 (站点key, 已 normalized 的端点, 是否命中)。
func resolveGLMSite(cfg glmConfig, base string) (string, glmEndpoint, bool) {
	base = strings.ToLower(base)
	if k, ep, ok := matchGLMSite(base, cfg.Endpoints); ok {
		return k, ep.normalized(), true
	}
	if k, ep, ok := matchGLMSite(base, glmDefaultEndpoints); ok {
		return k, ep.normalized(), true
	}
	return "", glmEndpoint{}, false
}

// matchGLMSite 在 base 里找命中的 key，多个命中取最长；排序保证输出稳定。
func matchGLMSite(base string, m map[string]glmEndpoint) (string, glmEndpoint, bool) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var bestKey string
	bestLen := 0
	for _, k := range keys {
		kk := strings.ToLower(k)
		if strings.Contains(base, kk) && len(kk) > bestLen {
			bestKey, bestLen = k, len(kk)
		}
	}
	if bestKey != "" {
		return bestKey, m[bestKey], true
	}
	return "", glmEndpoint{}, false
}

// glmCachePath 返回按站点分文件的额度缓存路径，避免两套 GLM 共用一个缓存、
// 切 profile 时看到上一个账号的额度。
func glmCachePath(siteKey string) string {
	safe := strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-' {
			return r
		}
		return '_'
	}, siteKey)
	if safe == "" {
		safe = "default"
	}
	return filepath.Join(cacheDir, "glm_quota-"+safe+".json")
}

func glmAuthHeader(scheme, token string) (string, string) {
	if strings.EqualFold(scheme, "bearer") {
		return "Authorization", "Bearer " + token
	}
	return "Authorization", token
}

const (
	cReset  = "\033[0m"
	cDim    = "\033[38;5;240m"
	cGray   = "\033[38;5;245m"
	cGreen  = "\033[38;5;114m"
	cYellow = "\033[38;5;214m"
	cRed    = "\033[38;5;203m"
	cBlue   = "\033[38;5;109m"
	cMag    = "\033[38;5;176m"
)

var sep = cDim + " │ " + cReset

func configHome() string {
	if v := os.Getenv("XDG_CONFIG_HOME"); v != "" {
		return v
	}
	return filepath.Join(home, ".config")
}

func must(s string, err error) string {
	if err != nil {
		return os.Getenv("HOME")
	}
	return s
}

// ---------------------------------------------------------------------------
// 输入结构
// ---------------------------------------------------------------------------

type contextWindow struct {
	TotalInput  int64    `json:"total_input_tokens"`
	TotalOutput int64    `json:"total_output_tokens"`
	Size        int64    `json:"context_window_size"`
	UsedPct     *float64 `json:"used_percentage"`
}

type input struct {
	Model struct {
		ID          string `json:"id"`
		DisplayName string `json:"display_name"`
	} `json:"model"`
	TranscriptPath string          `json:"transcript_path"`
	ContextWindow  *contextWindow  `json:"context_window"`
	RateLimits     json.RawMessage `json:"rate_limits"`
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 终端宽度
//
// Claude Code 的 statusline 输入里**没有**宽度字段（--dump-input 可查），
// 而 statusline 的 stdout 是管道、不是 tty，所以只能自己去问终端：
// 打开 /dev/tty 拿控制终端，走 TIOCGWINSZ。纯 stdlib，不起子进程 ——
// 这东西每次重绘都会跑，fork 一个 tput 是不能接受的。
// 在 tmux 里 /dev/tty 给的是当前 pane 的宽度，正是我们要的那个。
// 拿不到就返回 0，调用方据此退回「不截断」，跟改动前行为一致。
func termWidth() int {
	f, err := os.Open("/dev/tty")
	if err != nil {
		return 0
	}
	defer f.Close()
	var ws struct{ Row, Col, Xpix, Ypix uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(),
		uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws)))
	if errno != 0 {
		return 0
	}
	return int(ws.Col)
}

// dispWidth 算的是「占几列」，不是字符数也不是字节数：
// ANSI 转义序列不占列，中文和 █ 这类宽字符占两列。
// 按字符数算的话中文段会被高估一倍，宽度判断全错。
func dispWidth(s string) int {
	w, inEsc := 0, false
	for _, r := range s {
		if inEsc {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				inEsc = false
			}
			continue
		}
		if r == 0x1b {
			inEsc = true
			continue
		}
		// 只有真正的双宽字符才算 2。制表符 │ 和方块 █░ 属于
		// East Asian Ambiguous/Neutral，实际占 1 列 —— 把它们算成 2，
		// 光是三个分隔符加两条进度条就会虚高十几列，导致过早丢字段。
		if unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) ||
			unicode.Is(unicode.Katakana, r) || unicode.Is(unicode.Hangul, r) ||
			(r >= 0xff01 && r <= 0xff60) || (r >= 0xffe0 && r <= 0xffe6) {
			w += 2
			continue
		}
		w++
	}
	return w
}

// fitSegs 从右往左丢，直到装得下。左边的先保住 —— 这就是为什么
// defaultLine 的顺序即优先级。width<=0（拿不到宽度）时原样返回。
func fitSegs(segs []string, width int) []string {
	if width <= 0 || len(segs) == 0 {
		return segs
	}
	sepW := dispWidth(sep)
	total := 0
	for i, s := range segs {
		total += dispWidth(s)
		if i > 0 {
			total += sepW
		}
	}
	for len(segs) > 1 && total > width {
		total -= dispWidth(segs[len(segs)-1]) + sepW
		segs = segs[:len(segs)-1]
	}
	return segs
}

func bar(pct float64, width int) string {
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	filled := int(pct/100*float64(width) + 0.5)
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

func pctColor(pct float64) string {
	switch {
	case pct >= 91:
		return cRed
	case pct >= 81:
		return cYellow
	default:
		return cGreen
	}
}

func humanTok(n int64) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1e6)
	case n >= 1000:
		return fmt.Sprintf("%.1fK", float64(n)/1e3)
	}
	return strconv.FormatInt(n, 10)
}

func fmtLimit(n int64) string {
	if n >= 1_000_000 {
		v := float64(n) / 1e6
		if v == float64(int64(v)) {
			return fmt.Sprintf("%.0fM", v)
		}
		return fmt.Sprintf("%.1fM", v)
	}
	return fmt.Sprintf("%dK", n/1000)
}

func loadJSON(path string, v interface{}) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

// canonJSON 把 JSON 规范化后再比 —— 直接比原始字节的话，键序或空白
// 变一下就会被当成「内容变了」。
func canonJSON(b json.RawMessage) []byte {
	var v interface{}
	if json.Unmarshal(b, &v) != nil {
		return b
	}
	out, err := json.Marshal(v)
	if err != nil {
		return b
	}
	return out
}

func saveJSON(path string, v interface{}) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ---------------------------------------------------------------------------
// provider 路由
// ---------------------------------------------------------------------------

func detectProvider() (string, string) {
	base := strings.ToLower(os.Getenv("ANTHROPIC_BASE_URL"))
	switch {
	case base == "" || strings.Contains(base, "api.anthropic.com"):
		return "anthropic", base
	case strings.Contains(base, "bigmodel.cn"), strings.Contains(base, "z.ai"),
		strings.Contains(base, "zhipu"):
		return "glm", base
	case strings.Contains(base, "deepseek"):
		return "deepseek", base
	case strings.Contains(base, "127.0.0.1"), strings.Contains(base, "localhost"),
		strings.Contains(base, "0.0.0.0"), strings.Contains(base, "[::1]"):
		return "local", base
	case strings.Contains(base, "openai"):
		return "openai", base
	}
	return "generic", base
}

// ---------------------------------------------------------------------------
// transcript 增量扫描
// ---------------------------------------------------------------------------

type totals struct {
	Input      int64 `json:"input"`
	Output     int64 `json:"output"`
	CacheRead  int64 `json:"cache_read"`
	CacheWrite int64 `json:"cache_write"`
	Ctx        int64 `json:"ctx"`
	Msgs       int   `json:"msgs"`

	// 燃烧速率用：只累加相邻消息间隔 <= idleGapMax 的部分，
	// 这样中间去吃个饭不会把速率稀释成毫无意义的数字
	FirstTS   int64 `json:"first_ts"`
	LastTS    int64 `json:"last_ts"`
	ActiveSec int64 `json:"active_sec"`

	// 工具调用次数。从 assistant 消息的 content 里的 tool_use 块统计。
	Tools    map[string]int `json:"tools,omitempty"`
	SawUsage bool           `json:"saw_usage"`
	SawCache bool           `json:"saw_cache"`

	// 增量游标
	Offset  int64  `json:"offset"`
	ModTime int64  `json:"mtime"`
	Head    string `json:"head"` // 文件首 64 字节的指纹，防日志轮转后错位续读
}

// headPrint 取文件开头 64 字节的哈希。文件被替换或重写时该值会变，
// 此时即使 offset <= size 也必须全量重扫。
func headPrint(f *os.File) string {
	buf := make([]byte, 64)
	n, _ := f.ReadAt(buf, 0)
	if n <= 0 {
		return ""
	}
	h := sha256.Sum256(buf[:n])
	return fmt.Sprintf("%x", h[:6])
}

func (t totals) total() int64 {
	return t.Input + t.Output + t.CacheRead + t.CacheWrite
}

// billable 排除 cache_read。缓存读在 token 数上占绝对多数（常见九成以上），
// 算进速率会让数字大到失去参考意义。
func (t totals) billable() int64 {
	return t.Input + t.Output + t.CacheWrite
}

// cacheHit 是提示词 token 里由缓存供给的比例。输出 token 不参与。
func (t totals) cacheHit() (float64, bool) {
	prompt := t.Input + t.CacheRead + t.CacheWrite
	if prompt == 0 {
		return 0, false
	}
	return float64(t.CacheRead) / float64(prompt) * 100, true
}

// burnRate 用活跃时长而非墙钟时长，空闲不稀释。
func (t totals) burnRate() (float64, bool) {
	if t.ActiveSec < 30 {
		return 0, false
	}
	return float64(t.billable()) / (float64(t.ActiveSec) / 60), true
}

const idleGapMax = 300 // 秒。超过这个间隔视为离开，不计入活跃时长

type contentBlock struct {
	Type string `json:"type"`
	Name string `json:"name"`
}

type txRecord struct {
	IsSidechain bool   `json:"isSidechain"`
	Timestamp   string `json:"timestamp"`
	Message     *struct {
		Content json.RawMessage `json:"content"`
		Usage   *struct {
			Input       int64 `json:"input_tokens"`
			Output      int64 `json:"output_tokens"`
			CacheRead   int64 `json:"cache_read_input_tokens"`
			CacheCreate int64 `json:"cache_creation_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

func scanCachePath(transcript string) string {
	h := sha256.Sum256([]byte(transcript))
	return filepath.Join(cacheDir, fmt.Sprintf("tx-%x.json", h[:8]))
}

// scanTranscript 只解析自上次以来新增的字节。
// 文件被截断或替换（size 变小）时退回全量重扫。
func scanTranscript(path string) (totals, bool) {
	var t totals
	if path == "" {
		return t, false
	}
	fi, err := os.Stat(path)
	if err != nil {
		return t, false
	}

	f, err := os.Open(path)
	if err != nil {
		return t, false
	}
	defer f.Close()

	head := headPrint(f)

	cp := scanCachePath(path)
	var cached totals
	incremental := false
	if err := loadJSON(cp, &cached); err == nil {
		// 三个条件缺一不可：游标没越界、时间没倒流、文件头没变
		if cached.Offset <= fi.Size() &&
			cached.ModTime <= fi.ModTime().Unix() &&
			cached.Head == head {
			t = cached
			incremental = true
		}
	}

	start := int64(0)
	if incremental {
		start = t.Offset
	} else {
		t = totals{}
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return t, false
	}

	r := bufio.NewReaderSize(f, 1<<20)
	consumed := start
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			// 末尾半行（正在写入）不消费，下次从这里继续
			break
		}
		consumed += int64(len(line))

		trimmed := strings.TrimSpace(string(line))
		if len(trimmed) == 0 || trimmed[0] != '{' {
			continue
		}
		var rec txRecord
		if json.Unmarshal([]byte(trimmed), &rec) != nil {
			continue
		}
		// subagent 的消息也写在同一份 JSONL 里，算进 ctx 会让数字随
		// subagent 起落而跳动
		if rec.IsSidechain || rec.Message == nil || rec.Message.Usage == nil {
			continue
		}
		u := rec.Message.Usage
		t.SawUsage = true
		t.Msgs++
		t.Input += u.Input
		t.Output += u.Output
		t.CacheRead += u.CacheRead
		t.CacheWrite += u.CacheCreate
		if u.CacheRead > 0 || u.CacheCreate > 0 {
			t.SawCache = true
		}
		if c := u.Input + u.CacheRead + u.CacheCreate; c > 0 {
			t.Ctx = c
		}
		// content 可能是字符串也可能是块数组，只在是数组时才找 tool_use
		if len(rec.Message.Content) > 0 && rec.Message.Content[0] == '[' {
			var blocks []contentBlock
			if json.Unmarshal(rec.Message.Content, &blocks) == nil {
				for _, b := range blocks {
					if b.Type == "tool_use" && b.Name != "" {
						if t.Tools == nil {
							t.Tools = map[string]int{}
						}
						t.Tools[b.Name]++
					}
				}
			}
		}
		if rec.Timestamp != "" {
			if ts, err := time.Parse(time.RFC3339, rec.Timestamp); err == nil {
				sec := ts.Unix()
				if t.FirstTS == 0 {
					t.FirstTS = sec
				}
				if t.LastTS > 0 {
					if gap := sec - t.LastTS; gap > 0 && gap <= idleGapMax {
						t.ActiveSec += gap
					}
				}
				t.LastTS = sec
			}
		}
	}

	t.Offset = consumed
	t.ModTime = fi.ModTime().Unix()
	t.Head = head
	_ = saveJSON(cp, t)
	return t, incremental
}

// ---------------------------------------------------------------------------
// 上下文占用
// ---------------------------------------------------------------------------

type ctxWinConfig struct {
	Default int64            `json:"default"`
	Models  map[string]int64 `json:"models"`
}

// contextLimit 返回 (窗口大小, 是否确定)。
// 注意不要拿 exceeds_200k_tokens 当 1M 窗口的代理 —— 它字面意思只是
// "已经超过 200k"，拿来切分母会导致越线瞬间百分比暴跌。
func contextLimit(in input) (int64, bool) {
	var cfg ctxWinConfig
	_ = loadJSON(ctxWinPath, &cfg)
	def := cfg.Default
	if def <= 0 {
		def = 200_000
	}

	id := strings.ToLower(strings.TrimSpace(in.Model.ID))

	if v, ok := cfg.Models[in.Model.ID]; ok && v > 0 {
		return v, true
	}
	for k, v := range cfg.Models {
		if strings.EqualFold(k, id) && v > 0 {
			return v, true
		}
	}
	// 子串匹配取最长 key，避免 glm-5 抢在 glm-5.2 前面
	bestLen, bestVal := 0, int64(0)
	keys := make([]string, 0, len(cfg.Models))
	for k := range cfg.Models {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		kl := strings.ToLower(k)
		if kl == "" {
			continue
		}
		if strings.Contains(id, kl) || strings.Contains(kl, id) {
			if len(kl) > bestLen && cfg.Models[k] > 0 {
				bestLen, bestVal = len(kl), cfg.Models[k]
			}
		}
	}
	if bestVal > 0 {
		return bestVal, true
	}

	blob := strings.ReplaceAll(id+" "+strings.ToLower(in.Model.DisplayName), " ", "")
	for _, m := range []string{"[1m]", "1mcontext", "1mtoken"} {
		if strings.Contains(blob, m) {
			return 1_000_000, true
		}
	}
	return def, false
}

// contextUsage 优先信任 Claude Code 原生的 context_window（v2.1.132+）。
// 该版本以前传的是会话累计而非当前上下文，表现为百分比超过 100%，
// 据此判定不可信并退回本地推算。
func contextUsage(in input, t totals) (float64, int64, string) {
	if cw := in.ContextWindow; cw != nil && cw.Size > 0 {
		var p float64 = -1
		if cw.UsedPct != nil {
			p = *cw.UsedPct
		} else if cw.TotalInput+cw.TotalOutput > 0 {
			p = float64(cw.TotalInput+cw.TotalOutput) / float64(cw.Size) * 100
		}
		if p >= 0 && p <= 100 {
			return p, cw.Size, "native"
		}
	}
	limit, known := contextLimit(in)
	if t.Ctx == 0 {
		return -1, limit, "none"
	}
	src := "guess"
	if known {
		src = "map"
	}
	return float64(t.Ctx) / float64(limit) * 100, limit, src
}

// ---------------------------------------------------------------------------
// 显示开关
// ---------------------------------------------------------------------------

type displayConfig struct {
	// 新式：显式布局，每个内层数组是一行
	Lines     [][]string `json:"lines"`
	ToolLimit *int       `json:"toolLimit"`

	// 旧式布尔开关，v2 配置文件里的写法。没有 lines 时用它们拼出单行，
	// 这样升级不会把用户的配置作废。
	CacheHit       *bool `json:"cacheHit"`
	BurnRate       *bool `json:"burnRate"`
	TokenBreakdown *bool `json:"tokenBreakdown"`
}

func on(p *bool, def bool) bool {
	if p == nil {
		return def
	}
	return *p
}

func (d displayConfig) toolLimit() int {
	if d.ToolLimit == nil || *d.ToolLimit <= 0 {
		return 4
	}
	return *d.ToolLimit
}

// layout 决定渲染哪些 widget、怎么分行。
// 优先级：显式 lines > 旧布尔开关推导 > 内置默认。
func (d displayConfig) layout() [][]string {
	if len(d.Lines) > 0 {
		return d.Lines
	}
	if d.CacheHit != nil || d.BurnRate != nil || d.TokenBreakdown != nil {
		row := []string{"model", "ctx", "quota", "tokens", "cost"}
		if on(d.CacheHit, true) {
			row = append(row, "cache")
		}
		if on(d.BurnRate, true) {
			row = append(row, "burn")
		}
		if on(d.TokenBreakdown, false) {
			row = append(row, "breakdown")
		}
		return [][]string{row}
	}
	return [][]string{defaultLine}
}

func loadDisplay() displayConfig {
	var d displayConfig
	_ = loadJSON(displayPath, &d)
	return d
}

// ---------------------------------------------------------------------------
// 计价
// ---------------------------------------------------------------------------

type modelPrice struct {
	Input      *float64 `json:"input"`
	Output     *float64 `json:"output"`
	CacheRead  *float64 `json:"cache_read"`
	CacheWrite *float64 `json:"cache_write"`
	Currency   string   `json:"currency"`
}

type pricingConfig struct {
	Correction map[string]float64    `json:"correction_factor"`
	Models     map[string]modelPrice `json:"models"`
}

// estimateCost 返回 (金额, 币种, 可信度)。
// 任一必需字段缺失就不出金额 —— 宁可不显示，也不显示一个错的。
func estimateCost(modelID string, t totals) (float64, string, string) {
	var cfg pricingConfig
	if loadJSON(pricingPath, &cfg) != nil {
		return 0, "", "none"
	}
	id := strings.ToLower(modelID)
	var entry modelPrice
	var key string
	for k, v := range cfg.Models {
		kl := strings.ToLower(k)
		if strings.Contains(id, kl) || strings.Contains(kl, id) {
			entry, key = v, k
			break
		}
	}
	if key == "" || entry.Input == nil || entry.Output == nil {
		return 0, "", "none"
	}
	cr, cw := *entry.Input, *entry.Input
	if entry.CacheRead != nil {
		cr = *entry.CacheRead
	}
	if entry.CacheWrite != nil {
		cw = *entry.CacheWrite
	}
	cost := (float64(t.Input)**entry.Input +
		float64(t.Output)**entry.Output +
		float64(t.CacheRead)*cr +
		float64(t.CacheWrite)*cw) / 1e6

	conf := "estimate"
	if f, ok := cfg.Correction[key]; ok && f > 0 {
		cost *= f
		conf = "calibrated"
	}
	cur := entry.Currency
	if cur == "" {
		cur = "USD"
	}
	return cost, cur, conf
}

func fmtMoney(cost float64, cur, conf string) string {
	sym := map[string]string{"USD": "$", "CNY": "¥"}[cur]
	if conf == "calibrated" {
		return fmt.Sprintf("%s%.3f", sym, cost)
	}
	return fmt.Sprintf("~%s%.3f*", sym, cost)
}

// ---------------------------------------------------------------------------
// 智谱额度：后台刷新 + 缓存，主路径永不等网络
// ---------------------------------------------------------------------------

type quotaBlob struct {
	TS    int64           `json:"ts"`
	Data  json.RawMessage `json:"data"`
	Error string          `json:"error,omitempty"`
}

func glmQuotaCached(siteKey string) (map[string]interface{}, time.Duration) {
	var blob quotaBlob
	_ = loadJSON(glmCachePath(siteKey), &blob)
	age := time.Since(time.Unix(blob.TS, 0))
	if age > quotaTTL {
		// 子进程继承 env，自己按 ANTHROPIC_BASE_URL 解析站点，无需传参。
		if exe, err := os.Executable(); err == nil {
			cmd := exec.Command(exe, "--refresh-quota")
			cmd.Stdout, cmd.Stderr, cmd.Stdin = nil, nil, nil
			_ = cmd.Start()
			go func() { _ = cmd.Wait() }()
		}
	}
	if len(blob.Data) == 0 {
		return nil, age
	}
	var m map[string]interface{}
	if json.Unmarshal(blob.Data, &m) != nil {
		return nil, age
	}
	return m, age
}

func glmQuotaRefresh() {
	token := os.Getenv("ANTHROPIC_AUTH_TOKEN")
	if token == "" {
		token = os.Getenv("ZHIPU_API_KEY")
	}
	if token == "" {
		return
	}
	cfg := loadGLMConfig()
	siteKey, ep, ok := resolveGLMSite(cfg, os.Getenv("ANTHROPIC_BASE_URL"))
	if !ok || ep.URL == "" {
		return
	}
	path := glmCachePath(siteKey)
	req, err := http.NewRequest("GET", ep.URL, nil)
	if err != nil {
		return
	}
	hk, hv := glmAuthHeader(ep.AuthScheme, token)
	req.Header.Set(hk, hv)
	req.Header.Set("Accept", "application/json")
	client := &http.Client{Timeout: netTimeout}
	resp, err := client.Do(req)
	if err != nil {
		_ = saveJSON(path, quotaBlob{TS: time.Now().Unix(), Error: err.Error()})
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return
	}
	_ = saveJSON(path, quotaBlob{TS: time.Now().Unix(), Data: body})
}

// dig 在嵌套结构里找第一个匹配的 key。
// 响应结构未公开确认，所以宽松匹配 —— 跑 --verify 看真实字段名。
func dig(obj interface{}, names ...string) (float64, bool) {
	switch v := obj.(type) {
	case map[string]interface{}:
		for _, n := range names {
			for k, val := range v {
				if strings.EqualFold(k, n) {
					if f, ok := toFloat(val); ok {
						return f, true
					}
				}
			}
		}
		keys := make([]string, 0, len(v))
		for k := range v {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if f, ok := dig(v[k], names...); ok {
				return f, true
			}
		}
	case []interface{}:
		for _, val := range v {
			if f, ok := dig(val, names...); ok {
				return f, true
			}
		}
	}
	return 0, false
}

func toFloat(v interface{}) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case int64:
		return float64(x), true
	case string:
		if f, err := strconv.ParseFloat(strings.TrimSuffix(x, "%"), 64); err == nil {
			return f, true
		}
	}
	return 0, false
}

func normPct(p float64) float64 {
	if p <= 1.0 {
		return p * 100
	}
	return p
}

// ---------------------------------------------------------------------------
// Anthropic 原生 rate_limits
// ---------------------------------------------------------------------------

func renderRateLimits(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var m map[string]interface{}
	if json.Unmarshal(raw, &m) != nil {
		return ""
	}
	var segs []string
	for _, pair := range []struct {
		label string
		keys  []string
	}{
		{"5h", []string{"five_hour", "session", "primary"}},
		{"wk", []string{"seven_day", "weekly", "secondary"}},
	} {
		var node interface{}
		for _, k := range pair.keys {
			if v, ok := m[k]; ok {
				node = v
				break
			}
		}
		if node == nil {
			continue
		}
		p, ok := dig(node, "used_percentage", "used_pct", "utilization", "percent_used", "used_percent")
		if !ok {
			used, ok1 := dig(node, "used", "used_tokens")
			lim, ok2 := dig(node, "limit", "total", "max")
			if !ok1 || !ok2 || lim == 0 {
				continue
			}
			p = used / lim * 100
		}
		p = normPct(p)
		segs = append(segs, fmt.Sprintf("%s%s %s %.0f%%%s",
			pctColor(p), pair.label, bar(p, 5), p, cReset))
	}
	return strings.Join(segs, sep)
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

// widgetCtx 把渲染一个 widget 需要的东西打包，避免每个 widget 重复取。
type widgetCtx struct {
	in       input
	raw      map[string]interface{}
	t        totals
	provider string
	modelID  string
}

// widgets 是名字到渲染函数的映射。返回空串表示"这次没什么可显示的"，
// 该 widget 会被整段跳过 —— 显示一个 "n/a" 只是占地方。
var widgets = map[string]func(widgetCtx) string{
	"model": func(c widgetCtx) string {
		n := c.in.Model.DisplayName
		if n == "" {
			n = c.in.Model.ID
		}
		if n == "" {
			return ""
		}
		return cMag + n + cReset
	},

	"quota": func(c widgetCtx) string {
		switch c.provider {
		case "anthropic":
			if s := renderRateLimits(c.in.RateLimits); s != "" {
				return s
			}
			return cGray + "quota n/a" + cReset
		case "glm":
			return renderGLMQuota()
		}
		return ""
	},

	"tokens": func(c widgetCtx) string {
		if !c.t.SawUsage {
			if c.provider == "anthropic" || c.provider == "glm" {
				return ""
			}
			return cRed + "no usage" + cReset
		}
		// 用 billable 不用 total：cache_read 常占九成以上，把它算进来
		// 会显示成 257M，看着像烧了两亿五，实际新产生的内容只有 5.3M。
		// 同一个理由 burn rate 早就照办了，这里之前漏了。
		// 完整四项在 breakdown widget 里，缓存占比看 cache widget。
		return cBlue + humanTok(c.t.billable()) + " tok" + cReset
	},

	"cost": func(c widgetCtx) string {
		// 优先用 Claude Code 自己算的花费 —— 它知道真实计费，比我们的价格表可信
		if v, ok := digRaw(c.raw, "total_cost_usd"); ok {
			if f, ok := toFloat(v); ok && f > 0 {
				return cYellow + fmt.Sprintf("$%.3f", f) + cReset
			}
		}
		if c.provider == "anthropic" || c.provider == "glm" || c.provider == "local" {
			return ""
		}
		if !c.t.SawUsage {
			return ""
		}
		cost, cur, conf := estimateCost(c.modelID, c.t)
		if conf == "none" {
			return cDim + "价格未填" + cReset
		}
		return cYellow + fmtMoney(cost, cur, conf) + cReset
	},

	"cache": func(c widgetCtx) string {
		h, ok := c.t.cacheHit()
		if !ok {
			return ""
		}
		return fmt.Sprintf("%scache %.0f%%%s", cDim, h, cReset)
	},

	"burn": func(c widgetCtx) string {
		b, ok := c.t.burnRate()
		if !ok {
			return ""
		}
		return fmt.Sprintf("%s%s/min%s", cDim, humanTok(int64(b)), cReset)
	},

	"breakdown": func(c widgetCtx) string {
		if !c.t.SawUsage {
			return ""
		}
		return fmt.Sprintf("%sin %s·out %s·cw %s·cr %s%s",
			cDim, humanTok(c.t.Input), humanTok(c.t.Output),
			humanTok(c.t.CacheWrite), humanTok(c.t.CacheRead), cReset)
	},

	"ctx": func(c widgetCtx) string {
		p, limit, src := contextUsage(c.in, c.t)
		if p < 0 {
			return ""
		}
		mark := ""
		if src == "guess" {
			mark = "?"
		}
		return fmt.Sprintf("%sctx %s %.0f%%%s %s%s%s%s",
			pctColor(p), bar(p, 5), p, cReset, cDim, fmtLimit(limit), mark, cReset)
	},

	// 工具调用次数，按次数降序取前几个。看一眼就知道这个 session 在干嘛。
	"tools": func(c widgetCtx) string {
		if len(c.t.Tools) == 0 {
			return ""
		}
		type kv struct {
			k string
			v int
		}
		xs := make([]kv, 0, len(c.t.Tools))
		for k, v := range c.t.Tools {
			xs = append(xs, kv{k, v})
		}
		sort.Slice(xs, func(i, j int) bool {
			if xs[i].v != xs[j].v {
				return xs[i].v > xs[j].v
			}
			return xs[i].k < xs[j].k
		})
		n := loadDisplay().toolLimit()
		if len(xs) > n {
			xs = xs[:n]
		}
		parts := make([]string, 0, len(xs))
		for _, x := range xs {
			parts = append(parts, fmt.Sprintf("%s×%d", x.k, x.v))
		}
		return cDim + strings.Join(parts, " ") + cReset
	},

	"msgs": func(c widgetCtx) string {
		if c.t.Msgs == 0 {
			return ""
		}
		return fmt.Sprintf("%s%d msg%s", cDim, c.t.Msgs, cReset)
	},

	// 活跃时长，不是墙钟时长 —— 中间去吃饭不计入
	"duration": func(c widgetCtx) string {
		if c.t.ActiveSec < 60 {
			return ""
		}
		d := time.Duration(c.t.ActiveSec) * time.Second
		if d >= time.Hour {
			return fmt.Sprintf("%s%dh%dm%s", cDim, int(d.Hours()), int(d.Minutes())%60, cReset)
		}
		return fmt.Sprintf("%s%dm%s", cDim, int(d.Minutes()), cReset)
	},

	"dir": func(c widgetCtx) string {
		d := workspaceDir(c.raw)
		if d == "" {
			return ""
		}
		return cDim + filepath.Base(d) + cReset
	},

	// git 分支。直接读 .git/HEAD，不 fork subprocess。
	"git": func(c widgetCtx) string {
		b := gitBranch(workspaceDir(c.raw))
		if b == "" {
			return ""
		}
		return cBlue + "⎇ " + b + cReset
	},

	// 本次会话改了多少行。Claude Code 自己统计的，有才显示。
	"lines": func(c widgetCtx) string {
		add, ok1 := digRaw(c.raw, "total_lines_added")
		del, ok2 := digRaw(c.raw, "total_lines_removed")
		if !ok1 && !ok2 {
			return ""
		}
		a, _ := toFloat(add)
		d, _ := toFloat(del)
		if a == 0 && d == 0 {
			return ""
		}
		return fmt.Sprintf("%s+%.0f%s/%s-%.0f%s", cGreen, a, cReset, cRed, d, cReset)
	},
}

// 单行时的默认顺序。多行由 display.json 的 lines 决定。
// 顺序即优先级：窄了从右边开始丢，所以最该看的放最左。
// model 第一 —— 它是身份锚点，不看数字也得先知道自己在跟谁说话。
// ctx 第二 —— 决定你什么时候该 /compact，是唯一会逼你动手的数字。
// quota 第三 —— 5h/周额度，决定你还能不能继续。
// tokens 排在 cost 前面 —— 用量是你能直接控制的，钱只是它乘上单价的结果，
// 而且换 provider 时钱还可能压根估不准。
var defaultLine = []string{"model", "ctx", "quota", "tokens", "cost", "cache", "burn"}

func renderGLMQuota() string {
	cfg := loadGLMConfig()
	siteKey, ep, ok := resolveGLMSite(cfg, os.Getenv("ANTHROPIC_BASE_URL"))
	if !ok {
		return cGray + "quota n/a" + cReset
	}
	q, age := glmQuotaCached(siteKey)
	if q == nil {
		return cGray + "quota …" + cReset
	}
	var segs []string
	p, pok := dig(q, ep.Fields["used_pct"]...)
	if !pok {
		used, ok1 := dig(q, ep.Fields["used"]...)
		total, ok2 := dig(q, ep.Fields["total"]...)
		if ok1 && ok2 && total > 0 {
			p, pok = used/total*100, true
		}
	}
	if pok {
		p = normPct(p)
		segs = append(segs, fmt.Sprintf("%s5h %s %.0f%%%s", pctColor(p), bar(p, 5), p, cReset))
	} else {
		segs = append(segs, cRed+"字段未匹配"+cReset)
	}
	if p, ok := dig(q, ep.Fields["mcp_pct"]...); ok {
		p = normPct(p)
		segs = append(segs, fmt.Sprintf("%sMCP %.0f%%%s", pctColor(p), p, cReset))
	}
	if age > 3*quotaTTL {
		segs = append(segs, cDim+"stale"+cReset)
	}
	return strings.Join(segs, sep)
}

// digRaw 在 stdin 的原始 map 里递归找一个 key。
// Claude Code 会往里加字段（cost、行数变更等），结构没固定，宽松取。
func digRaw(m map[string]interface{}, name string) (interface{}, bool) {
	if m == nil {
		return nil, false
	}
	if v, ok := m[name]; ok {
		return v, true
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if sub, ok := m[k].(map[string]interface{}); ok {
			if v, ok := digRaw(sub, name); ok {
				return v, true
			}
		}
	}
	return nil, false
}

func workspaceDir(m map[string]interface{}) string {
	for _, k := range []string{"current_dir", "project_dir", "cwd"} {
		if v, ok := digRaw(m, k); ok {
			if s, ok := v.(string); ok && s != "" {
				return s
			}
		}
	}
	return ""
}

// gitBranch 从目录逐级向上找 .git，读 HEAD。不 fork git 进程。
func gitBranch(dir string) string {
	if dir == "" {
		return ""
	}
	for i := 0; i < 12 && dir != "/" && dir != "."; i++ {
		gitPath := filepath.Join(dir, ".git")
		if fi, err := os.Stat(gitPath); err == nil {
			head := filepath.Join(gitPath, "HEAD")
			if fi.Mode().IsRegular() {
				// worktree / submodule：.git 是文件，内容为 gitdir: <path>
				b, err := os.ReadFile(gitPath)
				if err != nil {
					return ""
				}
				line := strings.TrimSpace(string(b))
				if !strings.HasPrefix(line, "gitdir:") {
					return ""
				}
				head = filepath.Join(strings.TrimSpace(strings.TrimPrefix(line, "gitdir:")), "HEAD")
			}
			b, err := os.ReadFile(head)
			if err != nil {
				return ""
			}
			line := strings.TrimSpace(string(b))
			if ref := strings.TrimPrefix(line, "ref: refs/heads/"); ref != line {
				return ref
			}
			if len(line) >= 7 {
				return line[:7] // detached HEAD
			}
			return ""
		}
		dir = filepath.Dir(dir)
	}
	return ""
}

func render(in input, raw map[string]interface{}) string {
	provider, _ := detectProvider()
	modelID := in.Model.ID
	if modelID == "" {
		modelID = in.Model.DisplayName
	}
	t, _ := scanTranscript(in.TranscriptPath)
	c := widgetCtx{in: in, raw: raw, t: t, provider: provider, modelID: modelID}

	layout := loadDisplay().layout()
	tw := termWidth()
	out := make([]string, 0, len(layout))
	for _, row := range layout {
		segs := make([]string, 0, len(row))
		for _, name := range row {
			fn, ok := widgets[name]
			if !ok {
				continue
			}
			if s := fn(c); s != "" {
				segs = append(segs, s)
			}
		}
		if len(segs) > 0 {
			out = append(out, strings.Join(fitSegs(segs, tw), sep))
		}
	}
	return strings.Join(out, "\n")
}

// ---------------------------------------------------------------------------
// --verify
// ---------------------------------------------------------------------------

func cmdVerify() {
	fmt.Println("===== statusline router 自检 =====")
	fmt.Println()

	provider, base := detectProvider()
	fmt.Println("1. provider 路由")
	if base == "" {
		fmt.Println("   ANTHROPIC_BASE_URL = <未设置 -> 判定为 anthropic>")
	} else {
		fmt.Printf("   ANTHROPIC_BASE_URL = %s\n", base)
	}
	fmt.Printf("   -> 判定为: %s\n\n", provider)

	fmt.Println("2. pricing.json")
	var pc pricingConfig
	if err := loadJSON(pricingPath, &pc); err != nil {
		fmt.Printf("   ✗ 读取失败: %v\n\n", err)
	} else {
		var filled, empty []string
		for k, v := range pc.Models {
			if v.Input != nil && v.Output != nil {
				filled = append(filled, k)
			} else {
				empty = append(empty, k)
			}
		}
		sort.Strings(filled)
		sort.Strings(empty)
		fmt.Printf("   已填价格: %s\n", orNone(filled))
		fmt.Printf("   待填价格: %s\n\n", orNone(empty))
	}

	fmt.Println("3. transcript / usage 字段")
	latest, mt := latestTranscript()
	if latest == "" {
		fmt.Println("   ⚠️  没找到任何 transcript，先跑一轮对话再来")
		fmt.Println()
	} else {
		// 先清掉缓存测全量，再测增量，把差距显示出来
		_ = os.Remove(scanCachePath(latest))
		s1 := time.Now()
		t, _ := scanTranscript(latest)
		full := time.Since(s1)
		s2 := time.Now()
		_, inc := scanTranscript(latest)
		incr := time.Since(s2)

		fi, _ := os.Stat(latest)
		fmt.Printf("   最近的 transcript: %s\n", latest)
		if fi != nil {
			fmt.Printf("   大小: %.1f MB，最后修改: %s\n",
				float64(fi.Size())/(1<<20), mt.Format("2006-01-02 15:04"))
		}
		fmt.Printf("   记录到 usage 的消息数: %d\n", t.Msgs)
		fmt.Printf("   全量扫描 %v，增量扫描 %v", full.Round(time.Microsecond), incr.Round(time.Microsecond))
		if inc && full > 0 {
			fmt.Printf("（快 %.0f 倍）", float64(full)/float64(maxDur(incr, time.Microsecond)))
		}
		fmt.Println()

		if !t.SawUsage {
			fmt.Println("   ✗ 完全没有 usage 字段")
			fmt.Println("      -> 后端/shim 没回 usage，token 数会恒为 0。")
			fmt.Println("      -> 本地模型走 MLX shim 的话，这是最可能的坑。")
		} else {
			fmt.Printf("   ✓ input=%d output=%d cache_read=%d cache_write=%d\n",
				t.Input, t.Output, t.CacheRead, t.CacheWrite)
			if !t.SawCache {
				fmt.Println("   ⚠️  cache_read / cache_write 全为 0")
				fmt.Println("      -> 要么这个 session 真的没命中缓存，")
				fmt.Println("      -> 要么协议转换层把 cache 字段丢了。")
				fmt.Println("      -> 后者会让 DeepSeek 成本虚高约一个数量级（缓存价差 10 倍），")
				fmt.Println("         多跑几轮长会话再看，仍为 0 就按上限估算处理。")
			} else {
				fmt.Println("   ✓ cache 字段有值，成本估算可信")
			}
		}
		fmt.Println()
	}

	fmt.Println("4. 智谱额度接口")
	if provider == "glm" {
		glmQuotaRefresh()
		siteKey, _, ok := resolveGLMSite(loadGLMConfig(), os.Getenv("ANTHROPIC_BASE_URL"))
		var blob quotaBlob
		if ok && loadJSON(glmCachePath(siteKey), &blob) == nil && len(blob.Data) > 0 {
			fmt.Println("   ✓ 原始响应（字段名以此为准，必要时回来改 dig() 的取值）:")
			fmt.Println(truncate(prettyJSON(blob.Data), 1500))
		} else {
			fmt.Printf("   ✗ 请求失败或没有 ANTHROPIC_AUTH_TOKEN: %s\n", blob.Error)
		}
	} else {
		fmt.Println("   -  当前不在 GLM profile 下，跳过。切到 cc-glm / cc-ally-glm 再跑一次。")
	}
	fmt.Println()

	fmt.Println("5. 最近一次 statusline 输入（真实字段，非推测）")
	b, err := os.ReadFile(lastInput)
	if err != nil {
		fmt.Println("   ⚠️  还没有样本。跑一轮对话让 statusline 渲染一次再来。")
	} else {
		var m map[string]interface{}
		_ = json.Unmarshal(b, &m)
		if cw, ok := m["context_window"].(map[string]interface{}); ok {
			fmt.Println("   ✓ context_window 可用:")
			fmt.Printf("      context_window_size = %v\n", cw["context_window_size"])
			fmt.Printf("      used_percentage     = %v\n", cw["used_percentage"])
			fmt.Println("      -> 分母走原生字段，不需要维护 context_windows.json")
		} else {
			fmt.Println("   ✗ 没有 context_window 字段")
			fmt.Println("      -> 退回 context_windows.json，该模型需要手工填窗口大小")
		}
		if rl, ok := m["rate_limits"]; ok {
			rb, _ := json.MarshalIndent(rl, "      ", "  ")
			fmt.Println("   ✓ rate_limits 原始结构:")
			fmt.Println("      " + truncate(string(rb), 800))
			fmt.Println("      字段名跟 renderRateLimits() 对不上就照这个改")
		} else {
			fmt.Println("   -  没有 rate_limits（第三方 provider 下属正常）")
		}
		fmt.Printf("   完整样本: %s\n", lastInput)
	}
	fmt.Println()

	fmt.Println("6. 派生指标")
	if latest != "" {
		t, _ := scanTranscript(latest)
		if h, ok := t.cacheHit(); ok {
			fmt.Printf("   缓存命中率 %.1f%%\n", h)
		} else {
			fmt.Println("   缓存命中率 —— 无提示词 token，算不出")
		}
		if b, ok := t.burnRate(); ok {
			fmt.Printf("   燃烧速率 %.0f tok/min（活跃时长 %s，已剔除 >%ds 的空闲间隔）\n",
				b, (time.Duration(t.ActiveSec) * time.Second).String(), idleGapMax)
		} else {
			fmt.Printf("   燃烧速率 —— 活跃时长不足 30s 或 transcript 无 timestamp 字段\n")
		}
		fmt.Printf("   明细 in=%s out=%s cache_write=%s cache_read=%s\n",
			humanTok(t.Input), humanTok(t.Output), humanTok(t.CacheWrite), humanTok(t.CacheRead))
	} else {
		fmt.Println("   -  没有 transcript，跳过")
	}
	fmt.Printf("   显示开关: %s\n", displayPath)
	fmt.Println()

	fmt.Println("===== 自检结束 =====")
}

func maxDur(a, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}

func orNone(s []string) string {
	if len(s) == 0 {
		return "（无）"
	}
	return strings.Join(s, ", ")
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + " …"
}

func prettyJSON(raw json.RawMessage) string {
	var v interface{}
	if json.Unmarshal(raw, &v) != nil {
		return string(raw)
	}
	b, err := json.MarshalIndent(v, "   ", "  ")
	if err != nil {
		return string(raw)
	}
	return "   " + string(b)
}

func latestTranscript() (string, time.Time) {
	root := filepath.Join(home, ".claude", "projects")
	var best string
	var bestT time.Time
	_ = filepath.Walk(root, func(p string, fi os.FileInfo, err error) error {
		if err != nil || fi == nil || fi.IsDir() || !strings.HasSuffix(p, ".jsonl") {
			return nil
		}
		if fi.ModTime().After(bestT) {
			best, bestT = p, fi.ModTime()
		}
		return nil
	})
	return best, bestT
}

// ---------------------------------------------------------------------------
// --dump-input：列出最近一次 statusline 输入的全部字段
// ---------------------------------------------------------------------------

func cmdDumpInput() {
	b, err := os.ReadFile(lastInput)
	if err != nil {
		fmt.Println("还没有样本。跑一轮对话让 statusline 渲染一次再来。")
		return
	}
	var m map[string]interface{}
	if json.Unmarshal(b, &m) != nil {
		fmt.Println("样本不是合法 JSON:", lastInput)
		return
	}
	fmt.Println("===== 最近一次 statusline 输入 =====")
	fmt.Println()
	fmt.Println("Claude Code 会不定期往这里加字段。下面是这次实际收到的全部内容，")
	fmt.Println("看到有用的就加个 widget —— 不用猜，也不用查文档。")
	fmt.Println()
	dumpKeys(m, "")
	fmt.Println()
	fmt.Printf("完整样本: %s\n", lastInput)
}

func dumpKeys(m map[string]interface{}, prefix string) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		path := k
		if prefix != "" {
			path = prefix + "." + k
		}
		switch v := m[k].(type) {
		case map[string]interface{}:
			fmt.Printf("  %-34s {…}\n", path)
			dumpKeys(v, path)
		case []interface{}:
			fmt.Printf("  %-34s [%d 项]\n", path, len(v))
		case string:
			fmt.Printf("  %-34s %q\n", path, truncate(v, 60))
		default:
			fmt.Printf("  %-34s %v\n", path, v)
		}
	}
}

// ---------------------------------------------------------------------------
// --probe-glm：探测智谱额度接口的真实端点、鉴权方式和字段名
// ---------------------------------------------------------------------------

func cmdProbeGLM() {
	fmt.Println("===== 智谱额度接口探测 =====")
	fmt.Println()

	token := os.Getenv("ANTHROPIC_AUTH_TOKEN")
	if token == "" {
		token = os.Getenv("ZHIPU_API_KEY")
	}
	if token == "" {
		fmt.Println("✗ 没有 ANTHROPIC_AUTH_TOKEN / ZHIPU_API_KEY")
		fmt.Println("   请在 GLM profile 下运行本命令")
		return
	}
	fmt.Printf("   token 前缀 %s…（长度 %d）\n", safePrefix(token), len(token))
	base := os.Getenv("ANTHROPIC_BASE_URL")
	fmt.Printf("   ANTHROPIC_BASE_URL = %s\n", orEmpty(base))

	cfg := loadGLMConfig()
	siteKey, curEP, resolved := resolveGLMSite(cfg, base)
	if resolved {
		fmt.Printf("   解析站点: %s\n", siteKey)
		fmt.Printf("   将要尝试: %s（当前 auth=%s）\n", curEP.URL, curEP.AuthScheme)
	} else {
		fmt.Println("   ⚠️  当前 base_url 没匹配到任何配置站点，将只试内置默认端点")
	}
	fmt.Println()

	// 候选端点 = 当前站点 URL + 内置默认，去重后排序（输出顺序稳定）
	seen := map[string]bool{}
	var candidates []string
	add := func(u string) {
		if u != "" && !seen[u] {
			seen[u] = true
			candidates = append(candidates, u)
		}
	}
	if resolved {
		add(curEP.URL)
	}
	for _, e := range glmDefaultEndpoints {
		add(e.URL)
	}
	sort.Strings(candidates)

	type result struct {
		ep, scheme, body string
		code             int
	}
	var wins []result
	for _, ep := range candidates {
		for _, scheme := range []string{"raw", "bearer"} {
			code, body, err := glmTry(ep, scheme, token)
			label := fmt.Sprintf("%s  [%s]", ep, scheme)
			if err != nil {
				fmt.Printf("   ✗ %s\n      %v\n", label, err)
				continue
			}
			if code == 200 {
				fmt.Printf("   ✓ %s -> 200\n", label)
				wins = append(wins, result{ep, scheme, body, code})
			} else {
				fmt.Printf("   ✗ %s -> HTTP %d\n      %s\n", label, code, truncate(oneLine(body), 200))
			}
		}
	}
	fmt.Println()

	if len(wins) == 0 {
		fmt.Println("✗ 没有可用的组合。")
		fmt.Println("   可能是端点路径变了，或者你的套餐没有开放这个接口。")
		fmt.Println("   去 docs.bigmodel.cn/cn/coding-plan 查最新端点，")
		fmt.Printf("   然后写进 %s 对应站点的 url 字段。\n", glmCfgPath)
		return
	}

	w := wins[0]
	fmt.Println("=== 成功的响应（字段名以此为准）===")
	fmt.Println(truncate(prettyJSON(json.RawMessage(w.body)), 2000))
	fmt.Println()

	// 推断成功端点归属站点 key：优先当前站点，URL 对不上则按 URL 重推
	winSite := siteKey
	if winSite == "" || !strings.Contains(strings.ToLower(w.ep), strings.ToLower(winSite)) {
		winSite = defaultSiteKeyForURL(w.ep)
	}

	// 字段：用当前站点的 fields（保留用户已探测的映射），缺项补默认
	fields := map[string][]string{}
	if resolved {
		for k, v := range curEP.Fields {
			fields[k] = v
		}
	}
	for k, v := range glmDefaultFields {
		if _, ok := fields[k]; !ok {
			fields[k] = v
		}
	}

	var m map[string]interface{}
	if json.Unmarshal([]byte(w.body), &m) != nil {
		fmt.Println("⚠️  响应不是 JSON 对象，无法自动匹配字段（端点仍可用，下方配置照贴）")
	} else {
		fmt.Println("=== 字段匹配情况 ===")
		allOK := true
		for _, key := range []string{"used_pct", "used", "total", "mcp_pct"} {
			if v, ok := dig(m, fields[key]...); ok {
				fmt.Printf("   ✓ %-9s 命中，值 = %v\n", key, v)
			} else {
				fmt.Printf("   ✗ %-9s 没匹配上，候选名: %s\n", key, strings.Join(fields[key], ", "))
				if key == "used_pct" || key == "used" {
					allOK = false
				}
			}
		}
		fmt.Println()
		if allOK {
			fmt.Println("✓ 关键字段都能取到，直接写配置即可用。")
		} else {
			fmt.Println("⚠️  关键字段没匹配上。从上面的响应里找出对应的 key，")
			fmt.Println("   加进该站点 fields 里（是列表，可以多写几个候选）。")
		}
	}
	fmt.Println()

	// 输出可直接粘贴的 endpoints 结构：先带已有站点，只覆盖当前这条，其他站点不碰。
	out := map[string]glmEndpoint{}
	for k, v := range cfg.Endpoints {
		out[k] = v
	}
	out[winSite] = glmEndpoint{URL: w.ep, AuthScheme: w.scheme, Fields: fields}
	for k, v := range glmDefaultEndpoints {
		if _, exists := out[k]; !exists {
			out[k] = v
		}
	}

	fmt.Printf("建议写入 %s 的 endpoints（其他站点已带上，不会被覆盖）:\n\n", glmCfgPath)
	b, _ := json.MarshalIndent(glmConfig{Endpoints: out}, "", "  ")
	fmt.Println(string(b))
	fmt.Println()
	fmt.Println("改完不用重新编译，下次渲染就生效。")
}

func glmTry(endpoint, scheme, token string) (int, string, error) {
	req, err := http.NewRequest("GET", endpoint, nil)
	if err != nil {
		return 0, "", err
	}
	hk, hv := glmAuthHeader(scheme, token)
	req.Header.Set(hk, hv)
	req.Header.Set("Accept", "application/json")
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, string(body), nil
}

func safePrefix(s string) string {
	if len(s) <= 6 {
		return "***"
	}
	return s[:6]
}

func orEmpty(s string) string {
	if s == "" {
		return "<未设置>"
	}
	return s
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// ---------------------------------------------------------------------------
// --calibrate
// ---------------------------------------------------------------------------

type balanceInfo struct {
	Currency string `json:"currency"`
	Total    string `json:"total_balance"`
	Granted  string `json:"granted_balance"`
	ToppedUp string `json:"topped_up_balance"`
}

type balanceResp struct {
	Infos []balanceInfo `json:"balance_infos"`
}

type balSnapshot struct {
	TS       int64   `json:"ts"`
	Total    float64 `json:"total"`
	Granted  float64 `json:"granted"`
	ToppedUp float64 `json:"topped_up"`
	Currency string  `json:"currency"`
}

func cmdCalibrate() {
	fmt.Println("===== DeepSeek 余额差分校准 =====")
	fmt.Println()

	token := os.Getenv("ANTHROPIC_AUTH_TOKEN")
	if token == "" {
		token = os.Getenv("DEEPSEEK_API_KEY")
	}
	if token == "" {
		fmt.Println("✗ 没有 ANTHROPIC_AUTH_TOKEN / DEEPSEEK_API_KEY")
		fmt.Println("   需要在 cc-deepseek profile 下运行")
		return
	}

	req, _ := http.NewRequest("GET", "https://api.deepseek.com/user/balance", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		fmt.Printf("✗ 查询余额失败: %v\n", err)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	var br balanceResp
	if json.Unmarshal(body, &br) != nil || len(br.Infos) == 0 {
		fmt.Println("✗ 响应里没有 balance_infos")
		return
	}
	row := br.Infos[0]
	cur := balSnapshot{
		TS:       time.Now().Unix(),
		Currency: row.Currency,
		Total:    parseF(row.Total),
		Granted:  parseF(row.Granted),
		ToppedUp: parseF(row.ToppedUp),
	}
	fmt.Printf("当前余额: %s %.4f （赠送 %.4f / 充值 %.4f）\n",
		cur.Currency, cur.Total, cur.Granted, cur.ToppedUp)

	snapPath := filepath.Join(cacheDir, "deepseek_balance.json")
	var prev balSnapshot
	if loadJSON(snapPath, &prev) != nil || prev.TS == 0 {
		_ = saveJSON(snapPath, cur)
		fmt.Println("\n✓ 已记录基线快照。")
		fmt.Println("  正常用一段时间（建议跑掉几块钱的量）后再跑一次本命令，")
		fmt.Println("  才能算出真实扣费并回写 correction_factor。")
		return
	}

	spent := prev.Total - cur.Total
	hours := time.Since(time.Unix(prev.TS, 0)).Hours()
	fmt.Printf("\n距上次快照 %.1f 小时，实际扣费 %s %.4f\n", hours, cur.Currency, spent)
	if spent <= 0 {
		fmt.Println("⚠️  扣费为 0 或为负（可能中间充值过）。重置基线，稍后再试。")
		_ = saveJSON(snapPath, cur)
		return
	}
	fmt.Println("\n本地估算无法自动对齐到同一时间窗（transcript 按 session 分散），")
	fmt.Println("所以这一步给你数字，由你决定写不写回：")
	fmt.Println("  1. 打开平台的 per-key usage 导出，取同一时间段的估算总额 E")
	fmt.Printf("  2. correction_factor = %.4f / E\n", spent)
	fmt.Printf("  3. 填进 %s 的 correction_factor 里\n", pricingPath)
	fmt.Println("\n填了之后 statusline 的金额会去掉 ~ 和 * 标记。")
	_ = saveJSON(snapPath, cur)
}

func parseF(s string) float64 {
	f, _ := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return f
}

// ---------------------------------------------------------------------------
// --sync-pricing：从 LiteLLM 价目表同步单价进 pricing.json
// ---------------------------------------------------------------------------

// fetchLitellm 返回 (上游顶层 map, 数据日期, 来源标注, error)。
// 来源标注："live" = 这次联网拉到的；"cache" = 联网失败回退或 --offline 命中的缓存。
// 数据日期对 live 是今天，对 cache 是缓存写入那天的日期——绝不拿旧数据冒充新的。
func fetchLitellm(offline bool) (map[string]json.RawMessage, string, string, error) {
	var cached litellmCacheBlob
	hasCache := loadJSON(litellmCache, &cached) == nil && len(cached.Data) > 0

	if offline {
		if !hasCache {
			return nil, "", "", fmt.Errorf("--offline 但没有缓存（%s），先联网跑一次", litellmCache)
		}
		return decodeRawMap(cached.Data), cached.Fetched, "cache", nil
	}

	// 联网失败时只要本地有缓存就回退，并如实标成 cache。
	fallback := func() (map[string]json.RawMessage, string, string, error) {
		if hasCache {
			return decodeRawMap(cached.Data), cached.Fetched, "cache", nil
		}
		return nil, "", "", fmt.Errorf("拉取失败且无缓存")
	}

	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", litellmURL, nil)
	if err != nil {
		return fallback()
	}
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return fallback()
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fallback()
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return fallback()
	}
	if decodeRawMap(body) == nil {
		return fallback() // 不是合法 JSON 对象
	}
	today := time.Now().Format("2006-01-02")
	_ = saveJSON(litellmCache, litellmCacheBlob{TS: time.Now().Unix(), Fetched: today, Data: body})
	return decodeRawMap(body), today, "live", nil
}

type litellmCacheBlob struct {
	TS      int64           `json:"ts"`
	Fetched string          `json:"fetched"` // YYYY-MM-DD
	Data    json.RawMessage `json:"data"`
}

func decodeRawMap(raw json.RawMessage) map[string]json.RawMessage {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return nil
	}
	return m
}

// numField 从一个 raw 条目里取数值字段，容忍 float / int / 数字字符串。
// 社区文件里同一字段在不同条目类型不一致（实测 max_input_tokens 就有字符串），
// 任何解析失败都静默返回 false —— 单条目格式怪异不能搞挂整次同步。
func numField(entry map[string]json.RawMessage, key string) (float64, bool) {
	raw, ok := entry[key]
	if !ok || len(raw) == 0 {
		return 0, false
	}
	var v interface{}
	if json.Unmarshal(raw, &v) != nil {
		return 0, false
	}
	return toFloat(v)
}

// litellmPrice 是换算前（仍按每 token）从上游条目取出的四个单价，缺的为 nil。
type litellmPrice struct {
	input, output         *float64
	cacheRead, cacheWrite *float64
}

// extractPrices 取四个成本字段。input 缺失时返回的 input 为 nil，
// 调用方据此判定「这个上游条目不构成可填的价格」（如 sample_spec 那类文档条目）。
func extractPrices(up map[string]json.RawMessage) litellmPrice {
	var p litellmPrice
	if v, ok := numField(up, "input_cost_per_token"); ok {
		p.input = &v
	}
	if v, ok := numField(up, "output_cost_per_token"); ok {
		p.output = &v
	}
	if v, ok := numField(up, "cache_read_input_token_cost"); ok {
		p.cacheRead = &v
	}
	if v, ok := numField(up, "cache_creation_input_token_cost"); ok {
		p.cacheWrite = &v
	}
	return p
}

// matchUpstream 把我们的 key（常是裸名）映射到上游的 key（常是 provider/model）。
// 顺序：条目显式 upstream → 精确 → 后缀 /key 取最短 key（避开 *-batch/*-priority 等变体）。
func matchUpstream(ourKey string, entry, upstream map[string]json.RawMessage) (string, bool) {
	if ur, ok := entry["upstream"]; ok {
		var s string
		if json.Unmarshal(ur, &s) == nil && s != "" {
			if _, ok := upstream[s]; ok {
				return s, true
			}
		}
	}
	if _, ok := upstream[ourKey]; ok {
		return ourKey, true
	}
	suffix := "/" + ourKey
	best := ""
	for k := range upstream {
		if strings.HasSuffix(k, suffix) && (best == "" || len(k) < len(best)) {
			best = k
		}
	}
	if best != "" {
		return best, true
	}
	return "", false
}

// applyPrice 把换算后的价格写进条目，保留条目里的未知字段与 upstream。
// 写入的 source 标记让下次同步能认出这是托管条目、可以刷新。
func applyPrice(entry map[string]json.RawMessage, p litellmPrice, date string) map[string]json.RawMessage {
	out := make(map[string]json.RawMessage, len(entry)+5)
	for k, v := range entry {
		out[k] = v
	}
	setNum := func(k string, f *float64) {
		if f != nil {
			b, _ := json.Marshal(roundPrice(*f * 1e6))
			out[k] = b
		} else {
			out[k] = json.RawMessage("null")
		}
	}
	setNum("input", p.input)
	setNum("output", p.output)
	setNum("cache_read", p.cacheRead)
	setNum("cache_write", p.cacheWrite)
	if _, ok := out["currency"]; !ok {
		out["currency"] = json.RawMessage(`"USD"`)
	}
	sb, _ := json.Marshal("litellm@" + date)
	out["source"] = sb
	return out
}

func roundPrice(v float64) float64 {
	return math.Round(v*1e6) / 1e6
}

// isLitellmManaged：source 以 litellm@ 开头，即由本命令写入、可刷新的托管条目。
func isLitellmManaged(entry map[string]json.RawMessage) bool {
	var s string
	if r, ok := entry["source"]; ok {
		_ = json.Unmarshal(r, &s)
	}
	return strings.HasPrefix(s, "litellm@")
}

// fieldNonNull：字段存在且不是 JSON null。用来判定「手填过价格」。
func fieldNonNull(entry map[string]json.RawMessage, key string) bool {
	r, ok := entry[key]
	if !ok {
		return false
	}
	t := strings.TrimSpace(string(r))
	return t != "" && t != "null"
}

func hasManualPrice(entry map[string]json.RawMessage) bool {
	return fieldNonNull(entry, "input") || fieldNonNull(entry, "output")
}

func backupFile(path string) (string, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	dst := path + ".bak-" + time.Now().Format("20060102-150405")
	return dst, os.WriteFile(dst, src, 0o600)
}

func backupPricing() (string, error) {
	return backupFile(pricingPath)
}

func cmdSyncPricing(args []string) {
	var dryRun, offline, force bool
	var adds []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--dry-run":
			dryRun = true
		case a == "--offline":
			offline = true
		case a == "--force":
			force = true
		case a == "--add":
			if i+1 >= len(args) {
				fmt.Println("✗ --add 需要一个模型名参数")
				return
			}
			i++
			adds = append(adds, args[i])
		case a == "-h", a == "--help":
			fmt.Println("用法: claude-statusline --sync-pricing [--dry-run] [--offline] [--force] [--add <model>]")
			return
		default:
			fmt.Printf("✗ 未知参数: %s（--help 看用法）\n", a)
			return
		}
	}

	// 顶层用 map[string]json.RawMessage 读，_comment / correction_factor 原样保留。
	rawTop, readErr := os.ReadFile(pricingPath)
	if readErr != nil {
		rawTop = []byte(`{}`)
		fmt.Printf("⚠️  %s 不存在，从空骨架开始\n", pricingPath)
	}
	var top map[string]json.RawMessage
	if json.Unmarshal(rawTop, &top) != nil || top == nil {
		fmt.Printf("✗ %s 不是合法 JSON\n", pricingPath)
		return
	}
	models := decodeRawMap(top["models"])

	// --add：先塞空占位条目，后面统一走同步匹配。
	addSet := map[string]bool{}
	for _, m := range adds {
		m = strings.TrimSpace(m)
		if m == "" || addSet[m] {
			continue
		}
		addSet[m] = true
		if _, exists := models[m]; !exists {
			ph, _ := json.Marshal(modelPrice{Currency: "USD"})
			models[m] = ph
		}
	}

	upstream, date, source, err := fetchLitellm(offline)
	if err != nil {
		fmt.Printf("✗ %v\n", err)
		return
	}
	srcLabel := "实时拉取（" + date + "）"
	if source == "cache" {
		srcLabel = "缓存（" + date + "），联网失败已回退 —— 不是最新数据"
	}

	var updated, skippedManual, skippedNoMatch []string
	addOutcome := map[string]string{}
	newModels := make(map[string]json.RawMessage, len(models))

	keys := make([]string, 0, len(models))
	for k := range models {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, k := range keys {
		entry := decodeRawMap(models[k])
		managed := isLitellmManaged(entry)
		manual := !managed && hasManualPrice(entry)
		// 托管→刷新；空占位→填；手填→仅 --force 覆盖
		shouldFill := managed || force || !manual

		if !shouldFill {
			newModels[k] = models[k]
			skippedManual = append(skippedManual, k)
			continue
		}
		upKey, ok := matchUpstream(k, entry, upstream)
		if !ok {
			newModels[k] = models[k]
			skippedNoMatch = append(skippedNoMatch, k)
			if addSet[k] {
				addOutcome[k] = "无匹配，留空占位（手填或加 \"upstream\"）"
			}
			continue
		}
		p := extractPrices(decodeRawMap(upstream[upKey]))
		if p.input == nil || p.output == nil {
			newModels[k] = models[k]
			skippedNoMatch = append(skippedNoMatch, k)
			continue
		}
		newModels[k], _ = json.Marshal(applyPrice(entry, p, date))
		updated = append(updated, k+"  <-  "+upKey)
		if addSet[k] {
			addOutcome[k] = "已填入 <- " + upKey
		}
	}

	fmt.Println("===== 同步定价 =====")
	fmt.Printf("数据来源: %s\n\n", srcLabel)

	printList("已更新", updated)
	printList("跳过（手填，--force 才覆盖）", skippedManual)
	printList("跳过（上游无匹配）", skippedNoMatch)
	if len(addSet) > 0 {
		fmt.Println("新增条目:")
		for _, m := range adds {
			m = strings.TrimSpace(m)
			if m == "" {
				continue
			}
			fmt.Printf("   %s: %s\n", m, orEmpty2(addOutcome[m], "已在文件中，跳过"))
		}
	}

	// 判「变了没」必须比对最终结果，不能看 updated 的条数 —— 那记的是
	// 「上游匹配到了」，单价一个子儿没动也算数。这东西挂在 launchd 上每周
	// 跑一次，按 updated 判的话会无声攒出一堆内容相同的 .bak。
	// （register.py 当年就是栽在同一个坑上。）
	changed := false
	if len(newModels) != len(models) {
		changed = true
	} else {
		for k, v := range newModels {
			old, ok := models[k]
			if !ok || !bytes.Equal(canonJSON(old), canonJSON(v)) {
				changed = true
				break
			}
		}
	}
	switch {
	case dryRun:
		fmt.Println("\n（--dry-run，未写入）")
	case !changed:
		fmt.Println("\n无变更，未写入。")
	default:
		bak, berr := backupPricing()
		if berr != nil {
			fmt.Printf("\n✗ 备份失败: %v（已中止，未写入）\n", berr)
			return
		}
		fmt.Printf("\n已备份: %s\n", bak)
		top["models"], _ = json.Marshal(newModels)
		if err := saveJSON(pricingPath, top); err != nil {
			fmt.Printf("✗ 写入失败: %v\n", err)
			return
		}
		fmt.Println("已写入:", pricingPath)
	}

	fmt.Println()
	fmt.Println("提醒：上游是标准价目表，不含限时活动与错峰折扣；")
	fmt.Println("      实际扣费有偏差时用 --calibrate 算出 correction_factor 校正。")
}

func printList(title string, items []string) {
	if len(items) == 0 {
		return
	}
	fmt.Println(title + ":")
	for _, s := range items {
		fmt.Println("   " + s)
	}
}

func orEmpty2(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func main() {
	// statusline 崩了整行就没了，顶层兜底
	defer func() {
		if r := recover(); r != nil {
			fmt.Print(cDim + fmt.Sprintf("statusline panic: %v", r) + cReset)
		}
	}()

	_ = os.MkdirAll(cacheDir, 0o700)

	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--verify":
			cmdVerify()
			return
		case "--calibrate":
			cmdCalibrate()
			return
		case "--sync-pricing":
			cmdSyncPricing(os.Args[2:])
			return
		case "--probe-glm":
			cmdProbeGLM()
			return
		case "--dump-input":
			cmdDumpInput()
			return
		case "--refresh-quota":
			glmQuotaRefresh()
			return
		case "--version":
			fmt.Printf("claude-statusline %s\n", buildVersion)
			return
		}
	}

	raw, _ := io.ReadAll(io.LimitReader(os.Stdin, 8<<20))
	var in input
	var m map[string]interface{}
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &in)
		_ = json.Unmarshal(raw, &m)
	}
	// 留一份最近的 stdin，--verify 靠它报告真实字段名
	if len(m) > 0 {
		_ = os.WriteFile(lastInput, raw, 0o600)
	}

	fmt.Print(render(in, m))
}
