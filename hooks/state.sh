#!/usr/bin/env bash
# 由 Claude Code hooks 调用: state.sh <busy|wait|done|idle>
# STICKY_WAIT: wait 是粘性的 —— 只有 busy(你亲自输入) 或 idle(会话结束)
# 能清除它。Stop 不再能把 wait 降级成 done，否则真正需要你介入的窗口
# 会显示成"已完成"，比没有状态更糟。
DONE_TTL=900
NOTIFY=1
TITLE=1
TITLE_STORE=120

STATE="${1:-idle}"
[ -z "${TMUX_PANE:-}" ] && exit 0
command -v tmux >/dev/null 2>&1 || exit 0

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

printf '%s %s' "$STATE" "$(date +%s)" > "$F" 2>/dev/null || true
tmux set-option -p -t "$TMUX_PANE" @claude_state "$STATE" 2>/dev/null || true

# --- pane 标题：把你输入的第一句存进 @claude_prompt -----------------------
# busy 只由 UserPromptSubmit 触发（事件表见 scripts/register.py），所以这里
# 读到的 stdin 一定是那个事件的 JSON，prompt 字段就是你敲的内容。
#
# [ ! -t 0 ] 不能省：手动在终端里跑 state.sh busy 时 stdin 是 tty，
# python 会一直等 EOF，把整个 hook 卡死。
if [ "$TITLE" = "1" ] && [ "$STATE" = "busy" ] && [ ! -t 0 ] \
   && command -v python3 >/dev/null 2>&1; then
    T="$(python3 -c '
import json, os, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
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
stripped = p.lstrip("。！？；，、.!?; \t\n")
# 第一句：中文标点 / 换行 / 后面跟空白的西文句读，取最先出现的那个。
# 西文句读要求后跟空白，否则 file.go、v2.1 这种会被从中间切开。
head = re.split(r"[。！？；，、\n]|[.!?;](?=\s|$)", stripped, 1)[0].strip()
# 整句都是标点时 stripped 为空，那就老老实实显示原文
p = head or stripped or p
p = re.sub(r"[\x00-\x1f\x7f]", " ", p)
p = re.sub(r"\s+", " ", p).strip()
n = int(sys.argv[1])
if len(p) > n:
    p = p[:n] + "…"
# tmux 会把 #[...] 当样式指令吃掉（#() 和 #{} 倒是不展开）。# 加倍才是字面量。
sys.stdout.write(p.replace("#", "##"))
' "$TITLE_STORE" "$DIR" 2>/dev/null)" || T=""
    [ -n "$T" ] && tmux set-option -p -t "$TMUX_PANE" @claude_prompt "$T" 2>/dev/null
fi
# 会话结束就把标题摘掉，否则 pane 回到 shell 了边框还挂着上一轮的输入
[ "$STATE" = "idle" ] && tmux set-option -pu -t "$TMUX_PANE" @claude_prompt 2>/dev/null

tmux refresh-client -S 2>/dev/null || true

# 刚进入 wait 且开了通知：喊一声。这是唯一你不该错过的状态。
if [ "$STATE" = "wait" ] && [ "$PREV" != "wait" ] && [ "$NOTIFY" = "1" ]; then
    W="$(tmux display-message -p -t "$TMUX_PANE" '#I:#W' 2>/dev/null)"
    # 不用 tmux display-message：它会接管整条状态栏，
    # 正好在你最需要看标签栏的时候把标签栏盖住。
    if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"${W}\" with title \"Claude 需要你介入\" sound name \"Funk\"" >/dev/null 2>&1 || true
    fi
fi
exit 0
