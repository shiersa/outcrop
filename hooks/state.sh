#!/usr/bin/env bash
# 由 Claude Code hooks 调用: state.sh <busy|wait|done|idle>
# STICKY_WAIT: wait 是粘性的 —— 只有 busy(你亲自输入) 或 idle(会话结束)
# 能清除它。Stop 不再能把 wait 降级成 done，否则真正需要你介入的窗口
# 会显示成"已完成"，比没有状态更糟。
DONE_TTL=900
NOTIFY=1

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
