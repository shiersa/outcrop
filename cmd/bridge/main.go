// claude-bridge：本地 Anthropic → OpenAI 协议转换代理。
//
// 让 Claude Code 用上只有 OpenAI 兼容端点的模型（opencode Go 的 GLM 系、
// kimi-k2.x、gpt-5.6-luna 这类）。Claude Code 把 ANTHROPIC_BASE_URL 指到
// 本进程，本进程把 /v1/messages 翻译成上游的 /v1/chat/completions，响应
// （含 SSE 流）再反着翻回来。
//
// 定位是数据面正路径 —— 和 statusline（挂了少一行）不同，这东西挂了会话
// 直接断。所以：
//   1. 无状态。每个请求独立翻译，进程里不存任何会话数据，随时可重启。
//   2. 不碰密钥。入站的 x-api-key / Authorization 原样转成上游的 Bearer，
//      密钥只过手不落盘。
//   3. 第一版只对准 opencode Go 一个上游，quirk 面可控。挂了退回 cc-go
//      的 Anthropic 兼容模型，主链路不受影响。
//
// 已知填不了的坑：prompt caching。OpenAI chat completions 没有 cache_control，
// 长会话 token 开销比走原生 Anthropic 协议大，这是协议层的鸿沟，不是 bug。
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

var buildVersion = "dev"

var (
	upstream = flag.String("upstream", "", "上游 OpenAI 兼容端点的 base URL，例 https://opencode.ai/zen/go")
	port     = flag.Int("port", 8399, "本地监听端口")
	showVer  = flag.Bool("version", false, "打印版本")
)

func main() {
	flag.Parse()
	if *showVer {
		fmt.Printf("claude-bridge %s\n", buildVersion)
		return
	}
	if *upstream == "" {
		fmt.Fprintln(os.Stderr, "✗ 缺 --upstream，例: claude-bridge --upstream https://opencode.ai/zen/go")
		os.Exit(1)
	}
	base := strings.TrimRight(*upstream, "/")

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/messages", func(w http.ResponseWriter, r *http.Request) { handleMessages(w, r, base) })
	mux.HandleFunc("/v1/messages/count_tokens", handleCountTokens)
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) { proxyModels(w, r, base) })
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"ok":true,"upstream":%q,"version":%q}`, base, buildVersion)
	})

	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	log.Printf("claude-bridge %s 监听 %s -> %s", buildVersion, addr, base)
	// 只绑 127.0.0.1：这东西转发密钥，绝不能暴露到局域网
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("✗ %v", err)
	}
}

// upstreamClient 不设整体超时：长生成的流式响应可以跑几分钟，掐总时长
// 会把正常请求掐死。只掐「上游迟迟不吭声」——响应头 5 分钟不来才算死。
var upstreamClient = &http.Client{
	Transport: &http.Transport{ResponseHeaderTimeout: 5 * time.Minute},
}

// ---------------------------------------------------------------------------
// Anthropic 侧结构
// ---------------------------------------------------------------------------

type aReq struct {
	Model         string            `json:"model"`
	MaxTokens     int               `json:"max_tokens"`
	System        json.RawMessage   `json:"system,omitempty"`
	Messages      []aMsg            `json:"messages"`
	Tools         []aTool           `json:"tools,omitempty"`
	ToolChoice    json.RawMessage   `json:"tool_choice,omitempty"`
	Temperature   *float64          `json:"temperature,omitempty"`
	TopP          *float64          `json:"top_p,omitempty"`
	StopSequences []string          `json:"stop_sequences,omitempty"`
	Stream        bool              `json:"stream,omitempty"`
	// thinking / metadata / betas：上游不认，静默丢弃
}

type aMsg struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

type aBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text,omitempty"`
	ID        string          `json:"id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Input     json.RawMessage `json:"input,omitempty"`
	ToolUseID string          `json:"tool_use_id,omitempty"`
	Content   json.RawMessage `json:"content,omitempty"` // tool_result 的载荷
	IsError   bool            `json:"is_error,omitempty"`
	Source    *aImgSource     `json:"source,omitempty"`
	Thinking  string          `json:"thinking,omitempty"`
}

type aImgSource struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

type aTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	InputSchema json.RawMessage `json:"input_schema"`
}

// ---------------------------------------------------------------------------
// OpenAI 侧结构
// ---------------------------------------------------------------------------

type oMsg struct {
	Role       string      `json:"role"`
	Content    interface{} `json:"content,omitempty"`
	ToolCalls  []oToolCall `json:"tool_calls,omitempty"`
	ToolCallID string      `json:"tool_call_id,omitempty"`
}

type oToolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

type oUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	PromptDetails    *struct {
		CachedTokens int `json:"cached_tokens"`
	} `json:"prompt_tokens_details"`
}

// ---------------------------------------------------------------------------
// 请求翻译：Anthropic /v1/messages -> OpenAI /v1/chat/completions
// ---------------------------------------------------------------------------

// blocksOf 把 Anthropic 的 content 统一成块列表：string 等价于单个 text 块
func blocksOf(raw json.RawMessage) []aBlock {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return []aBlock{{Type: "text", Text: s}}
	}
	var bs []aBlock
	_ = json.Unmarshal(raw, &bs)
	return bs
}

// toolResultText 把 tool_result 的载荷压成字符串：string 直接用，
// 块数组取 text 拼接，其余整体 JSON 化 —— OpenAI 的 tool 消息只吃字符串。
func toolResultText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var bs []aBlock
	if json.Unmarshal(raw, &bs) == nil {
		var parts []string
		for _, b := range bs {
			if b.Type == "text" {
				parts = append(parts, b.Text)
			}
		}
		if len(parts) > 0 {
			return strings.Join(parts, "\n")
		}
	}
	return string(raw)
}

func convertRequest(ar *aReq) map[string]interface{} {
	var msgs []oMsg

	// system：顶层字段 -> 首条 system 消息。块数组时取 text 拼接
	// （cache_control 这类标注顺带就丢了 —— 上游本来也不认）。
	if len(ar.System) > 0 {
		var parts []string
		for _, b := range blocksOf(ar.System) {
			if b.Type == "text" {
				parts = append(parts, b.Text)
			}
		}
		if s := strings.Join(parts, "\n"); s != "" {
			msgs = append(msgs, oMsg{Role: "system", Content: s})
		}
	}

	for _, m := range ar.Messages {
		blocks := blocksOf(m.Content)
		switch m.Role {
		case "assistant":
			var texts []string
			var calls []oToolCall
			for _, b := range blocks {
				switch b.Type {
				case "text":
					texts = append(texts, b.Text)
				case "tool_use":
					tc := oToolCall{ID: b.ID, Type: "function"}
					tc.Function.Name = b.Name
					tc.Function.Arguments = string(b.Input)
					if tc.Function.Arguments == "" {
						tc.Function.Arguments = "{}"
					}
					calls = append(calls, tc)
				}
				// thinking 块不回传：OpenAI 侧没有对应物，上游会当普通文本
				// 混进上下文，比丢掉更糟
			}
			om := oMsg{Role: "assistant", ToolCalls: calls}
			if t := strings.Join(texts, ""); t != "" {
				om.Content = t
			}
			msgs = append(msgs, om)
		default: // user
			// tool_result 必须拆成独立的 tool 消息（OpenAI 的规矩：
			// 紧跟在带 tool_calls 的 assistant 消息之后），剩余的
			// text/image 再组成一条 user 消息。
			var rest []aBlock
			for _, b := range blocks {
				if b.Type == "tool_result" {
					txt := toolResultText(b.Content)
					if b.IsError {
						txt = "[tool error] " + txt
					}
					msgs = append(msgs, oMsg{Role: "tool", ToolCallID: b.ToolUseID, Content: txt})
				} else {
					rest = append(rest, b)
				}
			}
			if len(rest) == 0 {
				continue
			}
			hasImage := false
			for _, b := range rest {
				if b.Type == "image" {
					hasImage = true
				}
			}
			if !hasImage {
				var parts []string
				for _, b := range rest {
					if b.Type == "text" {
						parts = append(parts, b.Text)
					}
				}
				msgs = append(msgs, oMsg{Role: "user", Content: strings.Join(parts, "\n")})
			} else {
				// 带图：走 OpenAI 的多模态数组，图片转 data URI
				var arr []map[string]interface{}
				for _, b := range rest {
					switch b.Type {
					case "text":
						arr = append(arr, map[string]interface{}{"type": "text", "text": b.Text})
					case "image":
						if b.Source != nil {
							arr = append(arr, map[string]interface{}{
								"type": "image_url",
								"image_url": map[string]string{
									"url": "data:" + b.Source.MediaType + ";base64," + b.Source.Data,
								},
							})
						}
					}
				}
				msgs = append(msgs, oMsg{Role: "user", Content: arr})
			}
		}
	}

	out := map[string]interface{}{
		"model":    ar.Model,
		"messages": msgs,
	}
	if ar.MaxTokens > 0 {
		out["max_tokens"] = ar.MaxTokens
	}
	if ar.Temperature != nil {
		out["temperature"] = *ar.Temperature
	}
	if ar.TopP != nil {
		out["top_p"] = *ar.TopP
	}
	if len(ar.StopSequences) > 0 {
		out["stop"] = ar.StopSequences
	}
	if len(ar.Tools) > 0 {
		var tools []map[string]interface{}
		for _, t := range ar.Tools {
			tools = append(tools, map[string]interface{}{
				"type": "function",
				"function": map[string]interface{}{
					"name":        t.Name,
					"description": t.Description,
					"parameters":  json.RawMessage(t.InputSchema),
				},
			})
		}
		out["tools"] = tools
	}
	if len(ar.ToolChoice) > 0 {
		var tc struct {
			Type string `json:"type"`
			Name string `json:"name"`
		}
		if json.Unmarshal(ar.ToolChoice, &tc) == nil {
			switch tc.Type {
			case "auto":
				out["tool_choice"] = "auto"
			case "any":
				out["tool_choice"] = "required"
			case "none":
				out["tool_choice"] = "none"
			case "tool":
				out["tool_choice"] = map[string]interface{}{
					"type": "function", "function": map[string]string{"name": tc.Name},
				}
			}
		}
	}
	if ar.Stream {
		out["stream"] = true
		// 不开这个，usage 永远不来，statusline 和 Claude Code 的
		// context 跟踪就全瞎了
		out["stream_options"] = map[string]bool{"include_usage": true}
	}
	return out
}

// ---------------------------------------------------------------------------
// stop_reason / usage / 错误映射
// ---------------------------------------------------------------------------

func mapStopReason(fr string) string {
	switch fr {
	case "length":
		return "max_tokens"
	case "tool_calls", "function_call":
		return "tool_use"
	default: // stop / content_filter / ""
		return "end_turn"
	}
}

func mapUsage(u *oUsage) map[string]int {
	if u == nil {
		return map[string]int{"input_tokens": 0, "output_tokens": 0}
	}
	out := map[string]int{
		"input_tokens":  u.PromptTokens,
		"output_tokens": u.CompletionTokens,
	}
	if u.PromptDetails != nil && u.PromptDetails.CachedTokens > 0 {
		// 部分上游有自动缓存，尽量透传，statusline 的 cache 列才有数
		out["cache_read_input_tokens"] = u.PromptDetails.CachedTokens
		out["input_tokens"] = u.PromptTokens - u.PromptDetails.CachedTokens
	}
	return out
}

func errType(status int) string {
	switch {
	case status == 401:
		return "authentication_error"
	case status == 403:
		return "permission_error"
	case status == 404:
		return "not_found_error"
	case status == 429:
		return "rate_limit_error"
	case status == 529:
		return "overloaded_error"
	case status >= 500:
		return "api_error"
	default:
		return "invalid_request_error"
	}
}

func writeAErr(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"type":  "error",
		"error": map[string]string{"type": errType(status), "message": msg},
	})
}

// authOf 取入站请求的密钥：Claude Code 发 x-api-key，也兼容 Bearer。
// 只过手不落盘 —— bridge 自己没有任何密钥配置。
func authOf(r *http.Request) string {
	if k := r.Header.Get("x-api-key"); k != "" {
		return k
	}
	return strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
}

// ---------------------------------------------------------------------------
// /v1/messages 主路径
// ---------------------------------------------------------------------------

func handleMessages(w http.ResponseWriter, r *http.Request, base string) {
	if r.Method != http.MethodPost {
		writeAErr(w, 405, "method not allowed")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	if err != nil {
		writeAErr(w, 400, "read body: "+err.Error())
		return
	}
	var ar aReq
	if err := json.Unmarshal(body, &ar); err != nil {
		writeAErr(w, 400, "parse request: "+err.Error())
		return
	}

	oBody, err := json.Marshal(convertRequest(&ar))
	if err != nil {
		writeAErr(w, 500, "convert request: "+err.Error())
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), "POST", base+"/v1/chat/completions", bytes.NewReader(oBody))
	if err != nil {
		writeAErr(w, 500, err.Error())
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+authOf(r))

	resp, err := upstreamClient.Do(req)
	if err != nil {
		writeAErr(w, 502, "upstream: "+err.Error())
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// 上游错误体尽量把 message 挖出来再按 Anthropic 信封转出去，
		// 挖不到就原文透传 —— 别让「余额不足」显示成「HTTP 402」
		eb, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		msg := string(eb)
		var env struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(eb, &env) == nil && env.Error.Message != "" {
			msg = env.Error.Message
		}
		log.Printf("上游 %d: %.200s", resp.StatusCode, msg)
		writeAErr(w, resp.StatusCode, msg)
		return
	}

	if ar.Stream {
		streamResponse(w, resp.Body, ar.Model)
	} else {
		plainResponse(w, resp.Body, ar.Model)
	}
}

// ---------------------------------------------------------------------------
// 非流式响应
// ---------------------------------------------------------------------------

func plainResponse(w http.ResponseWriter, body io.Reader, model string) {
	raw, err := io.ReadAll(io.LimitReader(body, 64<<20))
	if err != nil {
		writeAErr(w, 502, "read upstream: "+err.Error())
		return
	}
	var or struct {
		ID      string `json:"id"`
		Choices []struct {
			Message struct {
				Content          string      `json:"content"`
				ReasoningContent string      `json:"reasoning_content"`
				ToolCalls        []oToolCall `json:"tool_calls"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
		Usage *oUsage `json:"usage"`
	}
	if err := json.Unmarshal(raw, &or); err != nil || len(or.Choices) == 0 {
		writeAErr(w, 502, "unexpected upstream response: "+truncStr(string(raw), 200))
		return
	}
	ch := or.Choices[0]

	var content []map[string]interface{}
	if ch.Message.ReasoningContent != "" {
		content = append(content, map[string]interface{}{
			"type": "thinking", "thinking": ch.Message.ReasoningContent, "signature": "",
		})
	}
	if ch.Message.Content != "" {
		content = append(content, map[string]interface{}{"type": "text", "text": ch.Message.Content})
	}
	for _, tc := range ch.Message.ToolCalls {
		var input json.RawMessage
		if json.Unmarshal([]byte(tc.Function.Arguments), &input) != nil {
			input = json.RawMessage("{}")
		}
		content = append(content, map[string]interface{}{
			"type": "tool_use", "id": tc.ID, "name": tc.Function.Name, "input": input,
		})
	}
	if content == nil {
		content = []map[string]interface{}{}
	}
	stop := mapStopReason(ch.FinishReason)
	if len(ch.Message.ToolCalls) > 0 {
		stop = "tool_use"
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"id":          orID(or.ID),
		"type":        "message",
		"role":        "assistant",
		"model":       model,
		"content":     content,
		"stop_reason": stop,
		"usage":       mapUsage(or.Usage),
	})
}

func orID(id string) string {
	if id != "" {
		return "msg_" + id
	}
	return fmt.Sprintf("msg_bridge_%d", time.Now().UnixNano())
}

func truncStr(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// ---------------------------------------------------------------------------
// 流式响应：OpenAI delta 流 -> Anthropic 事件流
//
// 状态机按块推进：thinking / text / tool_use 各占一个 index，类型切换时
// 关旧块开新块。工具调用最繁：OpenAI 把 id/name 只放在第一个碎片里，
// 参数 JSON 逐段流在 delta.tool_calls[].function.arguments，得原样转成
// input_json_delta 让 Claude Code 自己拼。
// ---------------------------------------------------------------------------

type sseWriter struct {
	w http.ResponseWriter
	f http.Flusher
}

func (s *sseWriter) event(name string, v interface{}) {
	b, _ := json.Marshal(v)
	fmt.Fprintf(s.w, "event: %s\ndata: %s\n\n", name, b)
	if s.f != nil {
		s.f.Flush()
	}
}

func streamResponse(w http.ResponseWriter, body io.Reader, model string) {
	fl, _ := w.(http.Flusher)
	s := &sseWriter{w: w, f: fl}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")

	s.event("message_start", map[string]interface{}{
		"type": "message_start",
		"message": map[string]interface{}{
			"id": orID(""), "type": "message", "role": "assistant", "model": model,
			"content": []interface{}{},
			"usage":   map[string]int{"input_tokens": 0, "output_tokens": 0},
		},
	})

	blockIdx := -1     // 当前块编号；-1 = 没有打开的块
	blockType := ""    // thinking / text / tool
	openAIToolIdx := -1 // OpenAI 侧的 tool_calls[].index，换号 = 换工具
	finish := ""
	var usage *oUsage

	closeBlock := func() {
		if blockIdx >= 0 {
			s.event("content_block_stop", map[string]interface{}{"type": "content_block_stop", "index": blockIdx})
			blockType = ""
		}
	}
	openBlock := func(t string, cb map[string]interface{}) {
		blockIdx++
		blockType = t
		cbOut := map[string]interface{}{"type": "content_block_start", "index": blockIdx, "content_block": cb}
		s.event("content_block_start", cbOut)
	}

	sc := bufio.NewScanner(body)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "[DONE]" {
			break
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content          string `json:"content"`
					ReasoningContent string `json:"reasoning_content"`
					ToolCalls        []struct {
						Index    int    `json:"index"`
						ID       string `json:"id"`
						Function struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
				FinishReason string `json:"finish_reason"`
			} `json:"choices"`
			Usage *oUsage `json:"usage"`
		}
		if json.Unmarshal([]byte(payload), &chunk) != nil {
			continue // 上游偶发的非 JSON 行（心跳注释等），跳过
		}
		if chunk.Usage != nil {
			usage = chunk.Usage
		}
		if len(chunk.Choices) == 0 {
			continue
		}
		d := chunk.Choices[0].Delta
		if fr := chunk.Choices[0].FinishReason; fr != "" {
			finish = fr
		}

		if d.ReasoningContent != "" {
			if blockType != "thinking" {
				closeBlock()
				openBlock("thinking", map[string]interface{}{"type": "thinking", "thinking": ""})
			}
			s.event("content_block_delta", map[string]interface{}{
				"type": "content_block_delta", "index": blockIdx,
				"delta": map[string]string{"type": "thinking_delta", "thinking": d.ReasoningContent},
			})
		}
		if d.Content != "" {
			if blockType != "text" {
				closeBlock()
				openBlock("text", map[string]interface{}{"type": "text", "text": ""})
			}
			s.event("content_block_delta", map[string]interface{}{
				"type": "content_block_delta", "index": blockIdx,
				"delta": map[string]string{"type": "text_delta", "text": d.Content},
			})
		}
		for _, tc := range d.ToolCalls {
			if blockType != "tool" || tc.Index != openAIToolIdx {
				closeBlock()
				openBlock("tool", map[string]interface{}{
					"type": "tool_use", "id": tc.ID, "name": tc.Function.Name, "input": map[string]interface{}{},
				})
				blockType = "tool"
				openAIToolIdx = tc.Index
			}
			if tc.Function.Arguments != "" {
				s.event("content_block_delta", map[string]interface{}{
					"type": "content_block_delta", "index": blockIdx,
					"delta": map[string]string{"type": "input_json_delta", "partial_json": tc.Function.Arguments},
				})
			}
		}
	}
	closeBlock()

	stop := mapStopReason(finish)
	s.event("message_delta", map[string]interface{}{
		"type":  "message_delta",
		"delta": map[string]interface{}{"stop_reason": stop, "stop_sequence": nil},
		"usage": mapUsage(usage),
	})
	s.event("message_stop", map[string]interface{}{"type": "message_stop"})
}

// ---------------------------------------------------------------------------
// count_tokens：上游没有对应接口，给个够用的估算。
// Claude Code 拿它做上下文预算的粗判，精确值随后每轮响应的 usage 会校准。
// ---------------------------------------------------------------------------

func handleCountTokens(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	// 混合文本按 ~3.5 字节/token 估：英文偏 4，中文偏 2-3，取中间
	n := len(body) * 2 / 7
	if n < 1 {
		n = 1
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"input_tokens":%d}`, n)
}

// proxyModels 透传 /v1/models，鉴权同样从入站映射成 Bearer
func proxyModels(w http.ResponseWriter, r *http.Request, base string) {
	req, err := http.NewRequestWithContext(r.Context(), "GET", base+"/v1/models", nil)
	if err != nil {
		writeAErr(w, 500, err.Error())
		return
	}
	req.Header.Set("Authorization", "Bearer "+authOf(r))
	resp, err := upstreamClient.Do(req)
	if err != nil {
		writeAErr(w, 502, "upstream: "+err.Error())
		return
	}
	defer resp.Body.Close()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}
