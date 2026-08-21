# outcrop

给 tmux 里的 Claude Code 加两层可见性。名字取自地质学的「露头」——
把埋在底下的状态露到地表。

## 两层分别解决什么

**状态图标** 回答「哪个窗口该看了」

- pane 边框：这个 pane 在跑 / 停了 / 等你介入
- window 标签栏：切走了也能看见别的 window 什么状态

**目录段** 回答「这块分屏在哪」

pane 边框上每块各显各的：

    ── ● 1:zsh ~/P/outcrop ───────────────────────
    ── · 2:zsh ~/W/BrandPal ──────────────────────
    ── · 3:zsh ~/P/o/c/statusline ────────────────

每一级只留首字母，末级留全名（`~/PrivateProject/outcrop` → `~/P/outcrop`）。

**标签栏上默认不显示目录**：那里的 `pane_current_path` 解析的是 window 的
当前 pane，一个 tab 分了屏它就只代表其中一块，却看着像整个 tab 的目录 ——
是误导。`--tab-dir` 可以开回来（这时才有「末级与窗口名重复就只显示父路径」
那套逻辑，`--dir-full` 关掉它）。

**分屏块数** 回答「这个 tab 里还藏着别的东西吗」

标签栏上分屏的 tab 会带一个 `▥3`，单 pane 的什么都不显示 —— 单 pane 是常态，
值得标出来的是「这里不止一块」：

    ● 3:outcrop [3]   4:shiersa-ontology-site [2]   5:BrandPal

`--no-pane-count` 关掉。

**pane 标题** 回答「这块在做什么」

边框上那个 `zsh` 是 `pane_current_command`，对 Claude Code 毫无信息量 ——
它是 node，进程名还常被显示成版本号（`2.1.231`）。所以跑着 Claude 的 pane
改显示你最近一次输入的第一句：

    ── 󰧟 1:我们需要做一个针对于tmux tab的优化 ~/P/outcrop ──
    ── 󰧟 2:/code-review high ~/W/BrandPal ────────────
    ── 󰧟 3:zsh ~/P/assay ────────────────────────────

按标点切句（`。！？；，、` 换行，或后面跟空白的 `.!?;`），然后**一句一句往后
加，加到 `--title-max` 列为止**，永远断在句子边界上。只取第一句的话，
「记一下，以后直接提交到 main」只会显示 6 列的「记一下」，边框大片空着：

    记一下，以后直接提交到 main          整条 27 列，装得下 -> 全显示
    其实我想做的是分屏，不过tab做了一可以    两句 37 列 -> 都显示
    我们需要做一个针对于tmux tab的优化，…   首句 34 列，再加就超 -> 只显示首句

西文句读要求后跟空白，否则 `main.go`、`v2.1`、`/opt/a/c.txt` 会被从中间切开。
开头的标点先剥掉，否则首段为空只能整句退回。没有标点就整句交给显示层按宽度截。

`UserPromptSubmit` hook 写进 pane 的 `@claude_prompt`，`SessionEnd` 摘掉，
所以 Claude 退出后边框自动变回 `zsh`。没有这个变量的 pane 行为完全不变。

pane 边框不做「与窗口名重复就省略」那套（边框上没有窗口名，不存在重复），
改为按 pane 宽度分三档降级：

标题、目录、session 徽标抢的是同一条边框，所以分档要连着算。徽标在序号后面，
**每一档都有**，所以计入固定开销：`OVH(12 + session-max + 2) + 标题上限 + DIR_MAX`。
默认值代入是 **98 / 78 / 40 / 36**（各档随 `--session-max` 变，见上一节的表）：

| pane 宽度 | 有标题 |
|---|---|
| ≥ 98 列 | 徽标 + 标题 ≤`--title-max`(40) + 完整路径 |
| ≥ 78 列 | 徽标 + 标题 ≤20 + 完整路径 |
| ≥ 40 列 | 徽标 + 标题 ≤10，无目录 |
| ≥ 36 列 | 徽标 + 标题 ≤8，无目录 |
| < 36 列 | 只留图标、序号和徽标 |

没有标题的 pane（普通 shell）走另一组写死的阈值，因为它不用给标题留位置：

| pane 宽度 | 无标题 |
|---|---|
| ≥ 46 列 | 进程名 + 完整路径 + 徽标 |
| ≥ 20 列 | 进程名 + 只留末级目录 + 徽标 |
| < 20 列 | 进程名，无目录 |

pane 宽度可以手动拖，**tmux 没有下限，能拖到 1 列**。所以最窄那档必须有下界：
低于「最短标题 + 标记」放得下的宽度就索性不显示标题 —— 否则一路交给 tmux
硬切，它切得干净（不会切坏多字节字符）但**不留任何截断标记**，你会以为
看到的就是全部。

有标题的窄 pane 直接不显示目录 —— 你要的是「这块在做什么」，目录标签栏上
还有一份。分档是为了不让 tmux 自己动手：它装不下时从右边硬切，切掉的正是
末级那个你要认的名字，而且切完看着还像个完整路径。

**session 名** 回答「这块是哪个会话，怎么点名」

跨会话通信（`@mention`、`/list-agents`、`SendMessage`）寻址用的是**会话名**，
不是 session id —— 那个 UUID 不参与寻址，也没人记得住。名字由 Claude Code 自己
起，规则是「小写目录名 + 两位十六进制」：

    outcrop-c1   brandpal-f3   assay-4d   assay-62

同一个目录开两个会话就靠后面那两位区分，而标签栏上它们都只写 `assay` ——
「多开几个窗口就找不着对应会话」正是这么来的。

徽标紧跟 pane 序号，**独立成一段、显示全名**：

    ── ● 1 outcrop-c1 我们需要做一个针对于tmux… ~/P/outcrop ──
    ── · 2 assay-4d zsh ~/P/assay ───────────────────────
    ── · 3:zsh ~/P/outcrop ──────────────────────────────

只在 pane 边框上，标签栏不动（理由见下）。

为什么不挂在路径尾巴上只显后缀（`~/P/outcrop-c1`）—— 那样省 12 列，但读着
像一个叫 `outcrop-c1` 的目录，而且剩下的 `c1` 没法直接拿去点名。**看到什么
就能打什么**是这个功能的全部意义，省下来的宽度不值得拿它换。

「这是哪一个」（序号 + 名字）语义上归一类，所以放在一起，排在「在做什么」
（标题）和「在哪」（目录）之前。

第三行那个冒号是有意的：**有徽标时标题前的分隔符是空格，没有时才是冒号**。
否则 `1 outcrop-c1:标题` 里那个冒号会被读成名字的一部分。普通 shell 的 pane
一如既往是 `3:zsh`。

截断**保末尾不保开头**（`…ontology-site-db`）：末尾那两位十六进制才是区分
同名会话的全部信息量，从右边砍掉的恰恰是它；开头本来就和目录名重复，猜得出来。
和 `--dir-max` 的取舍是同一条理由。上限 `--session-max` 默认 16，**每一档宽度
阈值都要为它留出 `N+2` 列**（前导空格 + 名字 + 截断标记），所以调大它的代价是
窄 pane 提前丢掉标题和目录：

| `--session-max` | 有标题各档起点 |
|---|---|
| 16（默认） | 98 / 78 / 40 / 36 |
| 10 | 92 / 72 / 34 / 30 |
| 6（下限） | 88 / 68 / 30 / 26 |
| `--no-session` | 80 / 60 / 22 / 18 |

**标签栏上不显示**，两个理由，任一条都够：

一是太长。会话名的前半截就是窗口名，标签栏上并排就成了
`outcrop outcrop-c1   assay assay-4d`，每个 tab 白占十几列去重复一遍自己 ——
而标签栏是整个界面里最挤的地方。

二是会误导。一个 window 分了屏、里面跑着两个会话时，那一格只有一个位置，
显示其中任意一个都是在暗示「整个 tab 是这个会话」—— 和 `pane_current_path`
一模一样的毛病，也正是目录段当初从标签栏撤下来的原因。

要找某个会话在哪个 window，靠状态图标定位到 tab、切过去看 pane 边框就行；
真同时开了两个同名会话，本来也得进到 window 里面才分得清是哪一块。

名字从 `~/.claude/sessions/<pid>.json` 读，pid 取自 `CLAUDE_CODE_MESSAGING_SOCKET`
的 basename，省掉一次目录扫描；这个变量不存在时（跨会话通信被关、或版本低于
2.1.224）退回按 tmux pane 反查 —— 注册表里正好存着 `"tmux":"<sess>:@<win>.%<pane>"`。
全程只用 grep 不用 python：这段每次 hook 都要跑，python 光启动就要 ~40ms。

`SessionStart` 写进 pane 的 `@claude_session`，`SessionEnd` 摘掉 —— 退出的会话
不会继续占着「这个 window 有几个会话」的名额，把单会话的 window 误判成有歧义。
`SessionStart` 刻意**不**映射成状态：`/clear` 和 resume 也会触发它，而 idle 是能
清除粘性 wait 的两个状态之一，那会把「真在等你决策」的信号悄悄抹掉。

**statusline** 回答「这个会话花了多少」

按 `ANTHROPIC_BASE_URL` 分派：

| provider | 显示 |
|---|---|
| Anthropic 订阅 | 原生 `rate_limits` 额度，**不显示金额** |
| Anthropic 按量付费 | 原生 `total_cost_usd` 金额 |
| 智谱 GLM | `glm.json` 配的额度接口 |
| DeepSeek / OpenAI | token + `pricing.json` 估算金额 |
| 自部署模型 | 只有 token，无金额 |

自部署不止跑在 localhost —— RFC1918 内网段（10./192.168./172.16-31.）和
`.internal` `.local` `.lan` `.intranet` 这些后缀也认。认不出来就会去查价目表
然后报「价格未填」，而自部署根本没有单价，那提示是在让你填一个不存在的东西。

## 安装

    ./install.sh

会编译二进制、部署 hook、写 tmux 配置、注册进所有 `CLAUDE_CONFIG_DIR`，
最后跑一遍完整性核查。已存在的配置文件不会被覆盖。

    ./install.sh --ascii        图标退成纯 ASCII（● ✓ · … 显示成方块时）
    ./install.sh --no-tmux      只装 statusline
    ./install.sh --no-notify    wait 时不发系统通知
    ./install.sh --done-ttl 0   done 状态不自动褪色
    ./install.sh --no-dir       pane 边框也不显示目录段
    ./install.sh --tab-dir      标签栏也显示目录（多 pane 时只代表当前那块）
    ./install.sh --no-pane-count 标签栏不显示分屏块数
    ./install.sh --no-session   不显示 session 名（跨会话通信点名用的那个）
    ./install.sh --session-max 10 session 名最多占几列（默认 16，保末尾截断）
    ./install.sh --dir-full     标签栏总是显示完整路径，不省略重复的末级
    ./install.sh --dir-max 12   目录段最多占几列，超出保末尾截断（默认 28）
    ./install.sh --no-title     pane 边框仍显示进程名，不显示你输入的内容
    ./install.sh --title-max 24 标题最多占几列（默认 40）
    ./install.sh --pricing-sync 装个 LaunchAgent，每周从 LiteLLM 同步第三方单价

`--dir-max` 截断**保末尾不保开头**（`…roject-name-that-exceeds-cap`）——
这套缩写的前提就是「末级留全名，那才是你要认的名字」，从右边砍掉的恰恰是它。
标记 `…` 落在开头。

顺带一提，**深路径根本触发不了截断**：六层深的
`~/PrivateProject/outcrop/cmd/statusline/internal/render` 缩完只有 18 列
（`~/P/o/c/s/i/render`）。真正会超的只有「末级名字本身很长」这一种。

随时核查：

    ./scripts/doctor.sh

卸载：

    ./uninstall.sh

## 在别的 Mac 上安装（免 Go）

目标机器不需要 Go，也不需要这个仓库。

1. 在有仓库的机器上打包（交叉编译 universal 二进制）：

       ./scripts/release.sh

   产出两种形式，内容一样：

   | 文件 | 用法 |
   |---|---|
   | `outcrop-<版本>-darwin-universal.sh` | `bash outcrop-<版本>.sh`，一条命令 |
   | `outcrop-<版本>-darwin-universal.tar.gz` | 老办法，解压后 `./install.sh` |

   自解压那份把 tar 直接接在一段 shell 头部后面，跑起来先自校验载荷
   （省掉手动 `shasum -c`），再解到临时目录调 `install.sh`，装完清理。
   全部开关照常透传：`bash outcrop-<版本>.sh --ascii --dir-max 12`。
   `--extract-only` 只解包不安装。

   不做 .pkg / .dmg：这个工具的安装是**配置合并**（往 `.tmux.conf` 塞
   managed block、合并 N 个 `settings.json` 且要保住别人的 hook），不是拖文件。
   pkg 没有命令行参数，七个开关全丢；29 项核查输出会被埋进安装器日志；
   macOS 的 pkg 还没有卸载机制。再加上没有 Developer ID 证书，双击会被
   Gatekeeper 拦——比 `./install.sh` 更麻烦，不是更省事。

   卸载器和核查脚本由 `install.sh` 装进 `~/.config/claude-tmux/tools/`，
   所以自解压包用完即弃，以后照样卸得掉、查得了。
   版本号取自 `git describe --tags --always --dirty`，注入进了二进制，
   `claude-statusline --version` 可查 —— 多台机器装不同版本时靠它分清。

2. 传到目标机器，校验后解压：

       shasum -a 256 -c outcrop-<版本>-darwin-universal.tar.gz.sha256
       tar xzf outcrop-<版本>-darwin-universal.tar.gz

3. 进目录装：

       cd outcrop && ./install.sh

`install.sh` 一份两用：包根目录有可执行的 `claude-statusline` 就走预编译
（直接 cp，无需 Go），没有就现场编译。预编译路径会 `xattr -dr
com.apple.quarantine` 去掉隔离属性 —— 二进制没有代码签名，从网络传过去 macOS
会隔离它，运行时报"无法验证开发者"。包里只含二进制和脚本，没有 `.go` / `go.mod`。

## 目录

    cmd/statusline/   Go 源码，只用标准库
    hooks/            两个 hook 脚本（部署时会注入 NOTIFY / DONE_TTL）
    tmux/setup.sh     managed block 生成
    scripts/register.py  settings.json 注册，事件表集中在这里
    scripts/doctor.sh    完整性核查，只读
    config/*.example  配置模板

## 状态语义

| 图标 | 颜色 | 含义 | 要你操作吗 |
|---|---|---|---|
| `?` | 黑字**橙底** | 选项询问 / 计划审批 / 权限请求。**粘性** —— 只有你输入或会话结束才清除 | **要** |
| `●` | 青 | 正在跑 | 不要 |
| `✓` | 绿 | 跑完了，默认 900 秒后褪成灰 | 不要 |
| `~` | 淡绿（done 绿的淡版） | 闲置 60 秒的提醒，同样 900 秒后褪成灰 | 不要 |
| `·` | 暗灰 | 空闲（标签栏上不显示，保持清爽） | 不要 |

wait 用底色不用前景色，是因为小图标在余光里太容易漏掉，而这是唯一不该错过
的状态。但底色是**橙不是红**、符号是 **`?` 不是 `!`** —— 红色和感叹号都读作
「出错了」，而 wait 的三个来源（选项询问 / 计划审批 / 权限请求）本质上都是
**在问你**。真出错时 Claude 自己会说，不需要标签栏来喊。

## statusline 布局

`~/.config/claude-statusline/display.json` 的 `lines` 决定每行显示什么：

`model` `quota` `ctx` `tokens` `cost` `cache` `burn` `breakdown`
`tools` `msgs` `duration` `dir` `git` `lines`

没数据的 widget 整段跳过，不显示占位符。改配置不需要重新编译。

**顺序即优先级**：终端窄了从右边开始丢，所以最该看的放最左。默认顺序是
`model` `ctx` `quota` `tokens` `cost` `cache` `burn` —— model 是身份锚点；
ctx 决定你什么时候该 /compact，是唯一会逼你动手的数字；quota 决定你还能
不能继续；tokens 排在 cost 前面 —— 用量是你能直接控制的，钱只是它乘上单价的
结果，换 provider 时还可能压根估不准。

`tokens` 数的是 in + out + cache_write，**不含 cache_read**。缓存读常占九成
以上，算进来会显示成 257M，看着像烧了两亿五，实际新产生的内容只有 5.3M。
完整四项看 `breakdown`，缓存占比看 `cache`。

    200 列  Opus 5 (1M context) │ ctx ███░░ 58% 1M │ 5h █░░░░ 25% │ wk ░░░░░ 8% │ $88.946 │ 235.6M tok │ cache 98% │ 31.4K/min
     96 列  Opus 5 (1M context) │ ctx ███░░ 58% 1M │ 5h █░░░░ 25% │ wk ░░░░░ 8% │ $88.946 │ 235.6M tok
     70 列  Opus 5 (1M context) │ ctx ███░░ 58% 1M │ 5h █░░░░ 25% │ wk ░░░░░ 8%
     50 列  Opus 5 (1M context) │ ctx ███░░ 58% 1M
     30 列  Opus 5 (1M context)

## 子命令

    claude-statusline --verify       自检
    claude-statusline --dump-input   列出 statusline 收到的全部字段
    claude-statusline --probe-glm    探测智谱额度接口的端点/鉴权/字段名
    claude-statusline --calibrate    DeepSeek 余额差分校准
    claude-statusline --sync-pricing 从 LiteLLM 价目表同步单价（手填条目不覆盖）

## 设计上值得记住的几件事

这些都是踩过之后才知道的，重构时别丢：

- **statusline 的输入里没有终端宽度。** `--dump-input` 可查 —— Claude Code
  给了 context_window / rate_limits / cost 等等，就是没有宽度。而 statusline
  的 stdout 是管道不是 tty，所以只能自己打开 `/dev/tty` 走 TIOCGWINSZ。
  纯 stdlib，不起子进程（这东西每次重绘都跑，fork 一个 tput 不能接受）。
  拿不到就退回「不截断」。
- **归属靠间距，不靠顺序。** 图标是 tab 的前缀，但原来它左右各 1 个空格、
  完全等距 —— `2:assay ● 3:outcrop` 里那个 `●` 读作谁的状态都行。把组间距
  拉到 2、组内保持 1 就消歧了（接近性原则）。没有反过来把图标贴紧数字，
  因为 `●` 是 Ambiguous 宽度，贴着会撞。
- **宽度有歧义的字符别用在需要精确对齐的地方。** `▥ ● ·` 都是 East Asian
  **Ambiguous**：按 CJK 配置的终端里占 2 列，其他终端占 1 列，而 tmux 按 1 列
  排版。`▥3` 后面紧跟数字、中间没空格，于是图标和数字挤到一起；`●` 后面有
  空格所以只是略宽、看不出来。分屏块数改用纯 ASCII 的 `[n]`。
- **算宽度时 `█░│` 是单宽，不是双宽。** 它们是 East Asian Ambiguous/Neutral。
  当成双宽的话，光是三个分隔符加两条进度条就虚高十几列，字段会被过早丢掉。
  真正双宽的只有 CJK 和全角形式。
- **分母是猜的时候，别打出自信的百分比。** 自部署模型 Claude Code 不给
  `context_window`，代码按默认 200K 猜，实际窗口更大时会显示「332%」——
  进度条早满了数字还在涨。原生路径本来就有 `p<=100` 的守卫，猜测路径漏了。
  超过 100% 就改报绝对量（`ctx 670.4K?`），那才是真信息；想要百分比就把
  窗口大小填进 `context_windows.json`。
- **订阅制下不显示金额。** `total_cost_usd` 在订阅制下的含义是「同样的量走
  按量付费 API 会花多少」——折合价，不是你被扣的钱，而它渲染成光秃秃的
  `$88.946`，看着就像真实账单。判据是 `rate_limits` 里有没有 5h / 周滚动
  窗口：按量付费的 API key 走每分钟 token/请求限流，不给这两个窗口。
  一个会被误读的数字，不如不展示。
- **「变了没」只能靠比对最终结果。** `--sync-pricing` 曾按「上游匹配到几条」
  判断，单价一个子儿没动也算变，于是每周一次的 launchd 任务会无声攒出一堆
  内容相同的 `.bak`。同一个坑 `register.py` 和 `tmux/setup.sh` 都栽过 ——
  凡是「先清空再重建」的写法，过程量都不能拿来当变更依据。
- **别猜百分比的单位，看字段名。** `used_percentage=1` 是「1%」，但曾被
  「`<=1` 就当成 0~1 的小数比例」这个启发式乘成 100% —— 进度条爆红，实际只
  用了 1%。这个启发式无论阈值定在哪都会错：`0.5` 既可能是 0.5% 也可能是
  50%。名字里带 percent/pct/percentage 的一律照单全收，只有 `utilization`
  这种没说单位的才轮得到猜。
  （本机 25% 恰好 >1，所以一直没暴露，换台机器用量低才发现。）
- **字段名差一个后缀就全盘失效。** `rate_limits.five_hour.used_percentage`
  曾经被写成找 `used_pct` / `used_percent`，于是额度一直显示 `quota n/a` ——
  数据一直都在。这类「猜字段名」的地方一定要用 `--dump-input` 对一遍实际输入。
- **同名字段靠数组顺序区分，等于没区分。** 智谱 `limits[]` 里三个限额**都叫
  `percentage`**（5h token 窗、更长的 token 窗、月度工具调用），只能靠兄弟字段
  `type`/`unit` 分辨。原先按裸名字递归取第一个命中，实测拿到的是 `TIME_LIMIT
  unit=5`（月度工具调用）—— 也就是标着 `5h` 的那个数字，一直在报另一个窗口。
  一次真实响应里前者 1%、后者 13%。现在候选名支持 `name@k=v&k2=v2` 过滤
  （`percentage@type=TOKENS_LIMIT&unit=3`），不再依赖顺序。
  刻意不留裸 `percentage` 兜底：过滤没命中说明上游改了 type/unit，退回「取第一个」
  等于恢复那个静默取错的行为 —— **显示不出来比显示错的强**。
- **HTTP 200 不等于成功。** 智谱两个站点都用 `{code,msg,success}` 包一层，
  token 不对时 HTTP 状态仍是 200，只有 body 里 `code=401 / success=false`。
  早先只判网络错误就把响应体当数据缓存，于是 401 的错误体被存下来，渲染时
  `dig` 在里面找不到字段，报出来的是「字段未匹配」—— 把鉴权问题显示成字段问题，
  指的方向完全是错的，人会去改 `fields` 而不是去查 token。
  失败要存进 `error` 字段并把原因显示出来（`额度 code 401: token …`），
  而不是显示成灰色的 `quota …` —— 那看着像还在加载，会让人一直等下去。
- **增量扫描是性能的全部来源。** 实测 30MB transcript：全量 ~310ms，
  增量 5-9ms。而同样全量扫描下 Go(319ms) 并不比 Python(307ms) 快 ——
  换语言换来的是单二进制和依赖确定性，不是速度。
- **缓存游标要校验文件头指纹。** 只判断 `offset <= size` 挡不住
  「截断后又长回超过旧游标」，那会从错误位置续读且完全不报错。
- **tmux 格式串里的逗号必须转义成 `#,`。** `#{?cond,a,b}` 用逗号分参数，
  样式指令里的裸逗号会把条件表达式拆散，结果是 `#[fg=colour231`
  被当字面量打出来。
- **macOS 自带 bash 3.2 会把非 ASCII 字节吃进变量名。**
  中文紧跟变量引用时必须写 `${VAR}`，否则 `set -u` 下直接崩。
- **标记的颜色必须跳出背景文字的色系。** hint 曾用 colour109（灰蓝），而
  标签栏自身的文字色是 `#6c7086` —— 同一个色系，图标看着像普通文字而不像
  标记。换成 done 绿的淡版（colour108）就分开了，语义上也连得住：hint 总是
  跟在 done 后面（跑完了又晾了一会儿）。
- **图标一律加粗。** 标签栏主题往往偏暗，细笔画在上面几乎看不出来。
  加粗不改色相，只把笔画加重 —— 比提亮颜色更不容易破坏「谁该抢眼」的次序。
- **同一族的字形在小字号下分不开。** `●` 和 `○` 只差一个填充，扫一眼认不出
  哪个是哪个。hint 改用 `~`，和 `●` 从轮廓上就不一样。
- **图标必须是有笔画的字符。** 曾经 busy/wait/done 三个图标是空串，格式串里
  只剩一个带颜色的空格——而空格没有笔画，只设前景色等于没设，于是 busy 和
  done 在标签栏上完全不可见，跟 idle 分不出来；只有 wait 因为设了背景色才
  看得见（一个红块）。四个状态里两个白做。也别用 Nerd Font 私有区字形：
  没装补丁字体的终端上是豆腐块，比空白更糟。
- **默认状态不该是安全色。** 曾经 `Stop` 后显示绿色，导致「等你做选择」
  的窗口看起来像「已完成」，隔天才被发现。现在 wait 是粘性的，
  done 会超时褪成灰。
- **`AskUserQuestion` / `ExitPlanMode` 走 `PreToolUse` 而不是 `Notification`。**
  只挂 Notification 的话，开着 bypass permissions 时计划审批完全没有信号。
- **回答 AskUserQuestion 不产生 `UserPromptSubmit`。** 那是工具结果，不是新的
  用户输入。而 wait 是粘性的、只有 busy/idle 能清除 —— 于是你答完之后整轮都
  卡在 wait，Claude 明明在干活，标签栏却一直显示「在问你」。补一条
  `PostToolUse(AskUserQuestion|ExitPlanMode) -> busy`：工具**返回**就等于你
  答完了。设计粘性状态时，必须为每个「粘住」的入口都想清楚出口在哪。
- **一个事件同时代表两件事，就不能只映射成一个状态。** `Notification` 既在
  「需要授权」时触发，也在「闲置 60 秒」时触发，后者根本不需要你做什么。
  它原先和真决策点共用最高警报，加上 wait 永不褪色，结果是三天前的一次闲置
  提醒一直挂着红底。现在它降级成独立的 hint（只给前景色，不给底色），
  真决策点由 `PreToolUse` 和 `PermissionRequest` 各自盖住。
- **告警的颜色和符号都要按语义挑，不是按强度挑。** wait 曾经是白字红底加
  `!`，但红色和感叹号都读作「出错了」，而 wait 的三个来源本质上是「在问你」。
  换成橙底加 `?`，余光里一样抓得住，语义却对了。强度对了不等于意思对了。
  抢眼的名额只有一个，得留给 wait —— 所以 busy 让出暖色改用青，
  它跑得再欢也不需要你看。
- **hint 也要褪色，wait 不褪。** 「闲了一会儿」挂三天更没意义；而真在等你
  决策的信号消失了比留着更糟。
- **不要用 `tmux display-message` 做通知。** 它接管整条状态栏，
  正好在你最需要看标签栏的时候把标签栏盖住。用系统通知。
- **`exceeds_200k_tokens` 不是「窗口是 1M」的代理。** 它字面意思只是
  「已经超过 200k」，拿来切分母会让百分比在越线瞬间从 99% 掉到 20%。
- **目录段一个子进程都不能起。** 标签栏每 `status-interval` 秒重绘，塞个
  `#()` 就是每 2 秒 × 每个 window 一个进程。整段缩写用 tmux 自带的格式串正则
  做完：`#{s|(\.?[^/])[^/]*/|\1/|:…}`。它吃掉分隔的斜杠后从下一级继续扫，
  所以一次全局替换处理任意深度，不用循环；末级没有尾随斜杠匹配不到，正好
  完整保留。需要 tmux ≥ 3.1（格式串正则 + 捕获组）。
- **标签栏的宽度是硬约束，超了 tmux 不报错。** 它会把一部分 tab 挪出可视区，
  看起来像「tab 丢了」。7 个 tab 加完整路径要 228 列而终端只有 215。
  `doctor.sh` 会算总宽度。目录段后来从标签栏撤掉，这条压力也就没了（69 列）。
- **一个值只对当前 pane 成立，就不该放在 window 级的位置上。**
  标签栏里的 `pane_current_path` 解析的是 window 的当前 pane，分屏后它只代表
  其中一块，却摆在代表整个 tab 的地方 —— 比不显示更糟，因为你会信它。
  目录段因此默认只留在 pane 边框上。
- **pane 边框装不下时 tmux 从右边硬切，且不留任何截断标记。**
  `~/P/o/c/statusline` 变成 `~/P/o/c/statu`，看着仍像个完整路径，比不显示
  更糟。所以按 `pane_width` 主动分档降级，宁可只显示末级。
- **`#{>=:a,b}` 是字典序，不是数值。** `"100" < "50"`，拿它判 pane 宽度会把
  最宽的 pane 判成最窄的。数值比较得写 `#{e|>=:a,b}`（注意参数用逗号分隔，
  不是冒号）。`#{?x,a,b}` 把字符串 `0` 当假，正好接得上。
- **用户输入进 tmux 格式串必须把 `#` 加倍。** 实测：`#()` 和 `#{}` 塞进
  user option 后不会被二次展开（所以没有命令注入），但 `#[fg=red]` 会在绘制
  阶段被当样式指令吃掉，边框配色就乱了。`##` 渲染成字面 `#`，替换掉就行 ——
  `C#`、`#123`、`#[...]` 都能原样显示。
- **每一档都要有下界。** pane 宽度能手动拖到 1 列，tmux 没有最小宽度。
  最窄那档如果一路管到底，下面就全靠 tmux 兜底 —— 而它不留截断标记。
  已知未覆盖的边角：无标题时的进程名没有上限，宽度 <12 且命令名很长时
  仍会被无标记硬切（`zsh`/`node` 这类短名不受影响）。
- **截断标记是额外加的，不算在长度里。** `#{=/28/…}` 最多占 **29** 列。
  分档公式里标题和目录各有一个标记，两个都得算进去 —— 漏算就在档位边界上
  溢出，tmux 默默从右边砍掉一截。（`#{=/-N/…}` 把标记放在开头，正好用来
  保末尾。）
- **`#{=N:...}` 的 N 只能是字面常数。** `#{=#{e|-:100,80}:x}` 渲染成空，
  嵌套变量更是直接把格式串打出来。所以宽度自适应只能写成若干档 `#{?}`，
  每档的常数要按该档的**最小**宽度算得下。
- **档位起点要反算，别拍脑袋。** pane 边框装饰实测恰好占 9 列
  （`── ` + 图标 + ` ` + `N:` + 目录前分隔空格 + 尾空格）。曾经按 8 估、
  把中档起点定在 46，结果 `9+20+18=47` 溢出 1 列，tmux 默默把目录末尾砍掉
  一个字符 —— 正是这套分档要防的事。`--dir-max` / `--title-max` 可调，
  起点必须跟着它们走。
- **第一句要先剥掉开头的标点。** 否则 `？开头是问号，第二句在这` 切出来的
  首段是空的，只能整句退回，两句全显示出来。
- **「只取第一句」在短句上会浪费掉整条边框。** 「记一下，以后直接提交到
  main」的首句只有 6 列，而边框有 40 列。改成按列数往后凑句子、凑满为止，
  且只在句子边界断开 —— 既不留白，也不会切出半句话。凑句子要按显示列数算，
  按字符数算中文只能用掉一半宽度。
- **截断按显示列数，不是字符数。** 40 列的 cap 对中文是 20 个字，
  tmux 自己算得对，不用额外处理。
- **UserPromptSubmit 是阻塞 hook。** 你按回车到 Claude 开始跑之间会等它。
  实测这套 python 解析约 35ms，可以接受；再重就该换进 Go 二进制了。
- **一个状态有多个入口时，payload 的形状也就不止一种。** `busy` 后来多了
  `PostToolUse` 这个来源，而 hook 里还按「busy 只可能来自 UserPromptSubmit」
  去取 `prompt` 字段 —— 于是每次答完选项都会往诊断文件里记一笔假报警。
  必须按 `hook_event_name` 分辨。（这条是自己的诊断机制抓出来的。）
- **拿不到就记下来，别静默退化。** hook 读不到 `prompt` 字段时，表现只是
  边框默默显示进程名，看不出是哪一环断的。所以把 payload 的字段名写进
  `last-hook-keys`，`doctor.sh` 会读出来告诉你实际字段叫什么。
- **备份要等到确定内容会变才做。** 重复跑 `install.sh` 是常态，早先无条件
  `cp` 一份，攒出了 70 份内容重复的 `.bak`。`register.py` 更隐蔽：它「先清掉
  自己的条目再重建」，那个 `changed` 标志在重建循环里被无条件置真，于是每次
  都判定「变了」。现在两处都改成比对最终结果，一样就既不落盘也不留备份。
- **删掉 managed block 不等于还原。** 活着的 tmux server 不会因为配置文件
  少了几行就回退选项值。凡是本项目 `set -g` 过的，都得先存进
  `orig-window-status.json` 再在卸载时逐条 `set-option` 回去 ——
  `pane-border-format` 就曾漏在外面，卸载后边框依旧是本项目的样子。
  例外是你自己在 `.tmux.conf` 里设过的（比如 `pane-border-style`），
  卸载时的 `source-file` 会把它们重新应用一遍，不用我们管。
- **数格式串里某个片段出现几次，必须 `grep -o | wc -l`。** `grep -c` 数的是
  行数，而两份格式串本来各占一行，套娃时行数不变，用 `-c` 永远发现不了。
- **「已包过一层」的判据要覆盖所有形态。** 只认 `claude_win_state` 会漏掉
  `--subshell`（图标走子进程，没这个串）和目录段，漏认就重复包装。

## 许可

MIT。见 [LICENSE](LICENSE)。
