#!/usr/bin/env bash
# 由 Claude Code hooks 调用: win-state.sh <state>，或 --read <window_id>
# 汇总 window 内所有 pane 的状态，取最高优先级。
# done 超过 DONE_TTL 秒自动当作 idle —— 满屏绿色会淹没真正需要看的信号。
DONE_TTL=900

DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tmux"
command -v tmux >/dev/null 2>&1 || exit 0

# hint 排在 done 下面：hint 是「跑完之后又晾了 60 秒」，比刚跑完更旧，
# 一个 window 里同时有这两种 pane 时该显示更新的那个。
rank() {
    case "$1" in
        wait) echo 4 ;;
        busy) echo 3 ;;
        done) echo 2 ;;
        hint) echo 1 ;;
        *)    echo 0 ;;
    esac
}

read_state() {
    # $1 = pane_id。输出状态，done / hint 过期则输出 idle
    # hint 也要褪 —— 它本来就是「闲了一会儿」，挂三天更没意义。
    # wait 不褪：真在等你决策的信号消失了比留着更糟。
    local f="$DIR/${1#%}" s t now
    [ -f "$f" ] || { echo ""; return; }
    s="$(cut -d' ' -f1 "$f" 2>/dev/null)"
    t="$(cut -d' ' -f2 "$f" 2>/dev/null)"
    case "$s" in
        done|hint)
            if [ "${DONE_TTL:-0}" -gt 0 ] && [ -n "$t" ]; then
                now="$(date +%s)"
                if [ $((now - t)) -gt "$DONE_TTL" ]; then echo ""; return; fi
            fi ;;
    esac
    echo "$s"
}

aggregate() {
    local win="$1" best="idle" best_r=0 p s r
    for p in $(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null); do
        s="$(read_state "$p")"
        [ -z "$s" ] && continue
        r="$(rank "$s")"
        if [ "$r" -gt "$best_r" ]; then best_r="$r"; best="$s"; fi
    done
    echo "$best"
}

if [ "${1:-}" = "--read" ]; then
    [ -n "${2:-}" ] || exit 0
    aggregate "$2"
    exit 0
fi

STATE="${1:-idle}"
[ -z "${TMUX_PANE:-}" ] && exit 0

WIN="$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)"
[ -z "$WIN" ] && exit 0

# 状态文件由 state.sh 负责写（含粘性逻辑），这里只做聚合
tmux set-option -w -t "$WIN" @claude_win_state "$(aggregate "$WIN")" 2>/dev/null || true
tmux refresh-client -S 2>/dev/null || true
exit 0
