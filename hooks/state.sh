#!/usr/bin/env bash
# 由 Claude Code hooks 调用: state.sh <busy|wait|done|idle>
# STICKY_WAIT: wait 是粘性的 —— 只有 busy(你亲自输入) 或 idle(会话结束)
# 能清除它。Stop 不再能把 wait 降级成 done，否则真正需要你介入的窗口
# 会显示成"已完成"，比没有状态更糟。
DONE_TTL=900
NOTIFY=1
TITLE=1
TITLE_STORE=120
# 往后凑句子凑到几列为止 —— 由 install.sh 按 --title-max 注入，
# 要和 pane 边框宽档的显示上限一致，否则要么留白要么白算
TITLE_FILL=40

STATE="${1:-idle}"
[ -z "${TMUX_PANE:-}" ] && exit 0
command -v tmux >/dev/null 2>&1 || exit 0

# --- session 名：跨会话通信的寻址用名 -------------------------------------
# 能拿去 @mention / SendMessage 的是 ~/.claude/sessions/<pid>.json 里的 name
# 字段，**不是** hook payload 里那个 session_id（UUID 谁也记不住，而且 ListAgents
# 根本不用它寻址）。pid 直接从 CLAUDE_CODE_MESSAGING_SOCKET 的 basename 取，
# 省掉一次目录扫描；变量不存在时（跨会话通信被关掉、或版本低于 2.1.224）
# 才退回按 tmux pane 反查 —— 注册表里正好存着 "tmux":"<sess>:@<win>.%<pane>"。
#
# 全程不用 python：这段每次 hook 都要跑，而 python 启动就要 ~40ms。注册表是
# 机器生成的单行 JSON，'"name":"' 这个前缀在里面唯一（"nameSource":" 前缀不同，
# 不会误命中）。
#
# 注册表跟着 CLAUDE_CONFIG_DIR 走：cc-glm / cc-go 这类 profile 的会话注册在
# ~/.claude-glm/sessions 等目录下。这里写死 ~/.claude 的话，第三方 profile 的
# pane 永远显示不出 session 名 —— 看起来像"只有官方账号才有"，其实是找错了地方。
# hook 是 claude 的子进程，能继承到 profile 入口设置的这个变量。
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"

_json_str() {  # _json_str <file> <key>
    grep -o "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -1 | cut -d'"' -f4
}

session_name() {
    local sf="" pid name
    if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
        pid="${CLAUDE_CODE_MESSAGING_SOCKET##*/}"; pid="${pid%.sock}"
        [ -f "$SESSION_DIR/$pid.json" ] && sf="$SESSION_DIR/$pid.json"
    fi
    if [ -z "$sf" ]; then
        sf="$(grep -l "\.${TMUX_PANE}\"" "$SESSION_DIR"/*.json 2>/dev/null | head -1)"
    fi
    [ -n "$sf" ] && [ -f "$sf" ] || return 1

    name="$(_json_str "$sf" name)"
    [ -n "$name" ] || return 1

    # 存全名，不做任何裁剪。徽标是独立一段（不再挂在路径尾巴上），只显示
    # 后缀的话就成了一个孤零零的 "c1"，没法直接拿去 @mention —— 而「看到什么
    # 就能打什么」正是这个功能的全部意义。
    # 装不下由显示层截断，那里才知道 pane 有多宽。
    # tmux 会把 #[...] 当样式指令吃掉，# 加倍才是字面量（和 @claude_prompt 同理）
    printf '%s' "$name" | sed 's/#/##/g'
}

# claude_pid 返回本 pane 里 Claude Code 进程的 pid，取不到就空。
# 用途是让别人判断「这个 pane 的会话是不是已经没了」——busy/wait 没有 TTL，
# SessionEnd 没跑到时会永久挂着。
#
# socket 的 basename 就是 pid（/tmp/cc-socks/85971.sock -> 85971），一次字符串
# 截取搞定。变量不在时退回注册表按 pane 反查。
#
# ⚠️ 判存活只能用 kill -0，**不能**拿 socket 文件是否存在当依据：
# 早于跨会话通信的 Claude Code 压根不建那个 socket，实测三个还在跑的
# 2.1.226 会话全都没有 socket，照 socket 判会把活会话全判成死的。
claude_pid() {
    local pid sf
    if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
        pid="${CLAUDE_CODE_MESSAGING_SOCKET##*/}"; pid="${pid%.sock}"
        case "$pid" in ''|*[!0-9]*) pid="" ;; esac
        [ -n "$pid" ] && { printf '%s' "$pid"; return 0; }
    fi
    sf="$(grep -l "\.${TMUX_PANE}\"" "$SESSION_DIR"/*.json 2>/dev/null | head -1)"
    [ -n "$sf" ] || return 1
    pid="$(grep -o '"pid":[0-9]*' "$sf" 2>/dev/null | head -1 | cut -d: -f2)"
    [ -n "$pid" ] && printf '%s' "$pid"
}

write_session_name() {
    local n
    n="$(session_name)" || return 0
    [ -n "$n" ] && tmux set-option -p -t "$TMUX_PANE" @claude_session "$n" 2>/dev/null
    return 0
}

# SessionStart 走这条：只把 session 名写进去，不碰状态。
# 不把它映射成 idle —— /clear 和 resume 也会触发 SessionStart，而 idle 是能清除
# 粘性 wait 的两个状态之一，那会把「真在等你决策」的信号悄悄抹掉。
if [ "$STATE" = "init" ]; then
    write_session_name
    tmux refresh-client -S 2>/dev/null || true
    exit 0
fi

DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tmux"
mkdir -p "$DIR" 2>/dev/null || exit 0
F="$DIR/${TMUX_PANE#%}"

PREV=""
[ -f "$F" ] && PREV="$(cut -d' ' -f1 "$F" 2>/dev/null)"

# 粘性：处于 wait 时，只有 busy / idle 能覆盖
if [ "$PREV" = "wait" ]; then
    case "$STATE" in
        busy|idle) ;;
        *) exit 0 ;;
    esac
fi

# 第三列是 claude 的 pid —— win-state.sh 靠它判断 busy/wait 是不是残留。
# 多写一列对老文件向后兼容：读的时候按 -f3 取，取不到就是空，行为不变。
printf '%s %s %s' "$STATE" "$(date +%s)" "$(claude_pid)" > "$F" 2>/dev/null || true
tmux set-option -p -t "$TMUX_PANE" @claude_state "$STATE" 2>/dev/null || true
# 每次都重写：/rename 之后名字会变，只在 SessionStart 写一次就会长期显示旧名
write_session_name

# --- pane 标题：把你输入的第一句存进 @claude_prompt -----------------------
# busy 有两个来源：UserPromptSubmit（你敲了东西）和 PostToolUse（你答完了
# AskUserQuestion）。只有前者带 prompt 字段，所以下面必须按 hook_event_name
# 分辨 —— 早先注释里写着「busy 只由 UserPromptSubmit 触发」，加了 PostToolUse
# 之后就不成立了，结果每次答完选项都会往诊断文件里记一笔「没有 prompt 字段」。
#
# [ ! -t 0 ] 不能省：手动在终端里跑 state.sh busy 时 stdin 是 tty，
# python 会一直等 EOF，把整个 hook 卡死。
if [ "$TITLE" = "1" ] && [ "$STATE" = "busy" ] && [ ! -t 0 ] \
   && command -v python3 >/dev/null 2>&1; then
    T="$(python3 -c '
import json, os, re, sys, unicodedata
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# 不是 UserPromptSubmit 就没什么可取的，安静退出（别记诊断）
if d.get("hook_event_name") not in ("", None, "UserPromptSubmit"):
    sys.exit(0)
p = (d.get("prompt") or "").strip()
if not p:
    # 拿不到就把 payload 的字段名记下来。否则字段哪天改名了，表现只是
    # 边框默默退回进程名，看不出是哪一环断的 —— doctor.sh 会读这个文件。
    try:
        with open(os.path.join(sys.argv[2], "last-hook-keys"), "w") as f:
            f.write(" ".join(sorted(str(k) for k in d)))
    except Exception:
        pass
    sys.exit(0)
try:
    os.remove(os.path.join(sys.argv[2], "last-hook-keys"))
except Exception:
    pass
# 开头的标点先剥掉，否则首段是空的，只能整句退回 ——
# 「？开头是问号，第二句在这」会把两句都显示出来。
stripped = p.lstrip("。！？；，、.!?; \t\n") or p


def cols(s):
    # 中文一个字占两列，按字符数算会让中文标题只用掉一半边框
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


# 句子边界：中文标点 / 换行 / 后面跟空白的西文句读。
# 西文句读要求后跟空白，否则 main.go、v2.1、/opt/a/c.txt 会被从中间切开。
SEP = re.compile(r"[。！？；，、\n]|[.!?;](?=\s|$)")
# 不是只取第一句 —— 第一句短的时候（「记一下，以后直接提交到 main」的
# 「记一下」只有 6 列）边框会大片空着。改成一句一句往后加，加到放不下为止，
# 且永远断在句子边界上，不会切出半句话。
bounds = [m.start() for m in SEP.finditer(stripped)] + [len(stripped)]
fill = int(sys.argv[3])
pick = bounds[0]          # 第一句就超宽也得留着，后面交给显示层截
for b in bounds:
    if cols(stripped[:b]) > fill:
        break
    pick = b
p = stripped[:pick].strip() or stripped
p = re.sub(r"[\x00-\x1f\x7f]", " ", p)
p = re.sub(r"\s+", " ", p).strip()
n = int(sys.argv[1])
if len(p) > n:
    p = p[:n] + "…"
# tmux 会把 #[...] 当样式指令吃掉（#() 和 #{} 倒是不展开）。# 加倍才是字面量。
sys.stdout.write(p.replace("#", "##"))
' "$TITLE_STORE" "$DIR" "$TITLE_FILL" 2>/dev/null)" || T=""
    [ -n "$T" ] && tmux set-option -p -t "$TMUX_PANE" @claude_prompt "$T" 2>/dev/null
fi
# 会话结束就把标题摘掉，否则 pane 回到 shell 了边框还挂着上一轮的输入
[ "$STATE" = "idle" ] && tmux set-option -pu -t "$TMUX_PANE" @claude_prompt 2>/dev/null
# session 名同样要摘：会话都结束了还挂着名字，标签栏的「只有一个 session
# 才显示」那条判断就会把已经死掉的 pane 算进去
[ "$STATE" = "idle" ] && tmux set-option -pu -t "$TMUX_PANE" @claude_session 2>/dev/null

tmux refresh-client -S 2>/dev/null || true

# 刚进入 wait 且开了通知：喊一声。这是唯一你不该错过的状态。
if [ "$STATE" = "wait" ] && [ "$PREV" != "wait" ] && [ "$NOTIFY" = "1" ]; then
    W="$(tmux display-message -p -t "$TMUX_PANE" '#I:#W' 2>/dev/null)"
    # 不用 tmux display-message：它会接管整条状态栏，
    # 正好在你最需要看标签栏的时候把标签栏盖住。
    if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"${W}\" with title \"Claude 需要你介入\" sound name \"Funk\"" >/dev/null 2>&1 || true
    elif command -v notify-send >/dev/null 2>&1; then
        # Linux 桌面走 libnotify。WSL/无桌面的服务器两者都没有，静默跳过 ——
        # 标签栏的橙底 wait 仍在，只是少了系统级弹窗。
        notify-send "Claude 需要你介入" "${W}" >/dev/null 2>&1 || true
    fi
fi
exit 0
