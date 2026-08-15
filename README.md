# outcrop

给 tmux 里的 Claude Code 加两层可见性。名字取自地质学的「露头」——
把埋在底下的状态露到地表。

## 两层分别解决什么

**状态图标** 回答「哪个窗口该看了」

- pane 边框：这个 pane 在跑 / 停了 / 等你介入
- window 标签栏：切走了也能看见别的 window 什么状态

**目录段** 回答「这个 tab / 这块分屏在哪」

标签栏每个 tab 后面跟一段缩写路径，开久了也不用靠记：

    1:vurnix ~/P   2:assay ~/P   5:BrandPal ~/W   6:api ~/W/BrandPal

每一级只留首字母，末级留全名（`~/PrivateProject/outcrop` → `~/P/outcrop`）。
末级和窗口名重复时只显示父路径 —— 窗口名本来就是目录名的话，再写一遍纯属
占地方，`~/P` 和 `~/W` 才是你要区分的那一位。改过窗口名或 cd 到别处，两者
不等，自动显示完整路径（上面的 `6:api`）。

分屏后标签栏只代表 window 当前 pane，其余几块没地方看，所以 pane 边框上也有
一份，各显示各的：

    ── 󰧟 1:zsh ~/P/outcrop ───────────────────────
    ── 󰧟 2:zsh ~/W/BrandPal ──────────────────────
    ── 󰧟 3:zsh ~/P/o/c/statusline ────────────────

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

标题和目录抢的是同一条边框，所以分档要连着算。各档起点由
`OVH + 标题上限 + DIR_MAX` 反算，默认值代入后是 68 / 48 / 20：

| pane 宽度 | 有标题 | 无标题 |
|---|---|---|
| ≥ 68 列 | 标题 ≤`--title-max`(40) + 完整路径 | 进程名 + 完整路径 |
| ≥ 48 列 | 标题 ≤20 + 完整路径 | 进程名 + 完整路径 |
| ≥ 20 列 | 标题 ≤10，无目录 | 进程名 + 只留末级 |
| < 20 列 | 标题 ≤8，无目录 | 进程名，无目录 |

有标题的窄 pane 直接不显示目录 —— 你要的是「这块在做什么」，目录标签栏上
还有一份。分档是为了不让 tmux 自己动手：它装不下时从右边硬切，切掉的正是
末级那个你要认的名字，而且切完看着还像个完整路径。

**statusline** 回答「这个会话花了多少」

按 `ANTHROPIC_BASE_URL` 分派：

| provider | 显示 |
|---|---|
| Anthropic | 原生 `rate_limits` 额度 |
| 智谱 GLM | `glm.json` 配的额度接口 |
| DeepSeek / OpenAI | token + `pricing.json` 估算金额 |
| 本地模型 | 只有 token，无金额 |

## 安装

    ./install.sh

会编译二进制、部署 hook、写 tmux 配置、注册进所有 `CLAUDE_CONFIG_DIR`，
最后跑一遍完整性核查。已存在的配置文件不会被覆盖。

    ./install.sh --ascii        Nerd Font 显示成豆腐块时用
    ./install.sh --no-tmux      只装 statusline
    ./install.sh --no-notify    wait 时不发系统通知
    ./install.sh --done-ttl 0   done 状态不自动褪色
    ./install.sh --no-dir       标签栏和 pane 边框都不显示目录段
    ./install.sh --dir-full     标签栏总是显示完整路径，不省略重复的末级
    ./install.sh --dir-max 12   目录段最多占几列，超出从右侧截断（默认 18）
    ./install.sh --no-title     pane 边框仍显示进程名，不显示你输入的内容
    ./install.sh --title-max 24 标题最多占几列（默认 40）

`--dir-max` 截断保左不保右：`~/P/shiersa-ontolo…` 留下的是区分用的 `~/P`。
tab 多到装不下时 tmux 会悄悄把一部分挪出可视区，`doctor.sh` 会算总宽度提前
警告你。

随时核查：

    ./scripts/doctor.sh

卸载：

    ./uninstall.sh

## 在别的 Mac 上安装（免 Go）

目标机器不需要 Go，也不需要这个仓库。

1. 在有仓库的机器上打包（交叉编译 universal 二进制）：

       ./scripts/release.sh

   产出 `dist/outcrop-<版本>-darwin-universal.tar.gz` 和 `.sha256`。
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

| 颜色 | 含义 |
|---|---|
| 白字红底 | 需要你介入。**粘性** —— 只有你输入或会话结束才清除 |
| 黄 | 正在跑 |
| 绿 | 跑完了，默认 900 秒后褪成灰 |
| 灰 | 空闲 |

## statusline 布局

`~/.config/claude-statusline/display.json` 的 `lines` 决定每行显示什么：

`model` `quota` `ctx` `tokens` `cost` `cache` `burn` `breakdown`
`tools` `msgs` `duration` `dir` `git` `lines`

没数据的 widget 整段跳过，不显示占位符。改配置不需要重新编译。

## 子命令

    claude-statusline --verify       自检
    claude-statusline --dump-input   列出 statusline 收到的全部字段
    claude-statusline --probe-glm    探测智谱额度接口的端点/鉴权/字段名
    claude-statusline --calibrate    DeepSeek 余额差分校准
    claude-statusline --sync-pricing 从 LiteLLM 价目表同步单价（手填条目不覆盖）

## 设计上值得记住的几件事

这些都是踩过之后才知道的，重构时别丢：

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
- **默认状态不该是安全色。** 曾经 `Stop` 后显示绿色，导致「等你做选择」
  的窗口看起来像「已完成」，隔天才被发现。现在 wait 是粘性的，
  done 会超时褪成灰。
- **`AskUserQuestion` / `ExitPlanMode` 走 `PreToolUse` 而不是 `Notification`。**
  只挂 Notification 的话，开着 bypass permissions 时计划审批完全没有信号。
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
  看起来像「tab 丢了」。7 个 tab 加完整路径要 228 列而终端只有 215 ——
  正因如此目录段默认省掉与窗口名重复的末级。`doctor.sh` 会算总宽度。
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
- **拿不到就记下来，别静默退化。** hook 读不到 `prompt` 字段时，表现只是
  边框默默显示进程名，看不出是哪一环断的。所以把 payload 的字段名写进
  `last-hook-keys`，`doctor.sh` 会读出来告诉你实际字段叫什么。
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
