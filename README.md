# outcrop

给 tmux 里的 Claude Code 加两层可见性。名字取自地质学的「露头」——
把埋在底下的状态露到地表。

## 两层分别解决什么

**状态图标** 回答「哪个窗口该看了」

- pane 边框：这个 pane 在跑 / 停了 / 等你介入
- window 标签栏：切走了也能看见别的 window 什么状态

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

随时核查：

    ./scripts/doctor.sh

卸载：

    ./uninstall.sh

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
