# outcrop

给 tmux 里的 Claude Code 加两层可见性。名字取自地质学的「露头」——
把埋在底下的状态露到地表。

## 两层

**状态图标**（hooks + tmux 格式串）

- pane 边框：这个 pane 在跑 / 停了 / 等你介入
- window 标签栏：切走了也能看见别的 window 什么状态
- 由 Claude Code hooks 驱动，wait 是粘性的，不会被 Stop 降级成绿色

**statusline**（Go 单二进制）

按 `ANTHROPIC_BASE_URL` 分派：

| provider | 显示 |
|---|---|
| Anthropic | 原生 `rate_limits` 额度 |
| 智谱 GLM | `glm.json` 配的额度接口 |
| DeepSeek / OpenAI | token + `pricing.json` 估算金额 |
| 本地模型 | 只有 token，无金额 |

上下文占用优先读 Claude Code 原生的 `context_window` 字段，
拿不到才退回 `context_windows.json`。

## 构建与安装

    ./install.sh

会编译到 `~/.config/claude-statusline/claude-statusline`，
部署 hooks 到 `~/.config/claude-tmux/`，
并把 `statusLine` 注册进所有 `CLAUDE_CONFIG_DIR`。

已存在的配置文件不会被覆盖。

## 布局

`~/.config/claude-statusline/display.json` 的 `lines` 决定每行显示什么。
可用 widget：`model` `quota` `ctx` `tokens` `cost` `cache` `burn`
`breakdown` `tools` `msgs` `duration` `dir` `git` `lines`。

没数据的 widget 整段跳过，不显示占位符。

## 子命令

    claude-statusline --verify       自检
    claude-statusline --dump-input   列出 statusline 收到的全部字段
    claude-statusline --probe-glm    探测智谱额度接口的端点/鉴权/字段名
    claude-statusline --calibrate    DeepSeek 余额差分校准

## 设计上值得记住的几件事

- **增量扫描是性能的全部来源。** 实测 30MB transcript：全量 ~310ms，
  增量 5-9ms。而同样全量扫描下 Go(319ms) 并不比 Python(307ms) 快 ——
  换语言换来的是单二进制和依赖确定性，不是速度。
- **缓存游标要校验文件头指纹。** 只判断 `offset <= size` 挡不住
  「截断后又长回超过旧游标」，那会从错误位置续读且完全不报错。
- **tmux 格式串里的逗号必须转义成 `#,`。** `#{?cond,a,b}` 用逗号分参数，
  样式指令里的裸逗号会把条件表达式拆散。
- **macOS 自带 bash 3.2 会把非 ASCII 字节吃进变量名。**
  中文紧跟变量引用时必须写 `${VAR}`。
- **默认状态不该是安全色。** 曾经 `Stop` 后显示绿色，导致「等你做选择」
  的窗口看起来像「已完成」，第二天才被发现。现在 done 会超时褪成灰。
