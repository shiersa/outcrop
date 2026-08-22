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

# 会话是不是还活着。$1 = 状态文件里记的 claude pid。
# 记不到 pid（老状态文件、或跨会话通信关着且注册表里查不到）时返回「活着」——
# 宁可留着一个可能过期的状态，也不能把真在等你决策的 wait 误清掉。
alive() {
    [ -n "${1:-}" ] || return 0
    kill -0 "$1" 2>/dev/null
}

read_state() {
    # $1 = pane_id。输出状态，done / hint 过期则输出 idle
    # hint 也要褪 —— 它本来就是「闲了一会儿」，挂三天更没意义。
    # wait 不褪：真在等你决策的信号消失了比留着更糟。
    local f="$DIR/${1#%}" s="" t="" p="" now
    [ -f "$f" ] || { echo ""; return; }
    # 用内建 read 而不是 cut：这个函数每个 pane 调一次、每次 hook 调一遍，
    # 三次 cut 就是三次 fork。状态文件写的时候没有结尾换行，所以 read 会返回
    # 非零，变量却已经填好了 —— || true 吃掉那个返回值。
    read -r s t p < "$f" 2>/dev/null || true
    case "$s" in
        done|hint)
            if [ "${DONE_TTL:-0}" -gt 0 ] && [ -n "$t" ]; then
                now="$(date +%s)"
                if [ $((now - t)) -gt "$DONE_TTL" ]; then echo ""; return; fi
            fi ;;
        busy|wait)
            # busy 和 wait 是仅有的两个没有 TTL 的状态，所以 SessionEnd 没跑到时
            # （Ctrl-C 硬退、终端被关、kill -9）会永久挂着 —— 尤其 wait 带橙色底，
            # 一个早就退出的会话会一直喊「该你了」。用进程是否还在来兜底。
            alive "$p" || { echo ""; return; } ;;
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

# 全局清理残留。只在 hook 触发时跑，不是定时任务 —— 代价是一次
# tmux list-panes -a 加每个 pane 一次 kill -0，都很便宜。
#
# 必须扫全部 window 而不只是当前这个：会话是在自己那个 pane 里死掉的，
# 而清理它的时机只能是「别处有 hook 触发」，那时当前 window 多半不是它。
#
# pane 已经不存在的状态文件顺手删掉，否则会无限攒下去。
# 被清理动过的 window，逗号分隔。只有这些需要重算聚合 ——
# 无脑重算全部 window 的代价是每次 hook 多 N 次 tmux list-panes fork，
# 而 hook 是同步阻塞 Claude 的，这台机器 23 个 window 就是 23 次。
SWEPT=""

sweep_dead() {
    local panes p f s pid w _
    # pane_id 本身就带 %，别再补一个，否则得到 %%11 谁也匹配不上
    panes=" $(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | tr '\n' ' ') "
    for f in "$DIR"/*; do
        [ -f "$f" ] || continue
        p="%${f##*/}"
        case "$p" in *[!%0-9]*) continue ;; esac   # 跳过 last-hook-keys 之类
        if [ "${panes#* $p }" = "$panes" ]; then
            rm -f "$f" 2>/dev/null
            continue
        fi
        s=""; pid=""
        read -r s _ pid < "$f" 2>/dev/null || true
        case "$s" in busy|wait) ;; *) continue ;; esac
        alive "$pid" && continue
        # 会话没了：状态文件和三个 pane 变量一起摘掉，边框回到 zsh + 无图标
        rm -f "$f" 2>/dev/null
        tmux set-option -pu -t "$p" @claude_state 2>/dev/null
        tmux set-option -pu -t "$p" @claude_prompt 2>/dev/null
        tmux set-option -pu -t "$p" @claude_session 2>/dev/null
        w="$(tmux display-message -p -t "$p" '#{window_id}' 2>/dev/null)"
        [ -n "$w" ] && case ",$SWEPT," in *",$w,"*) ;; *) SWEPT="${SWEPT}${SWEPT:+,}$w" ;; esac
    done
}

if [ "${1:-}" = "--read" ]; then
    [ -n "${2:-}" ] || exit 0
    aggregate "$2"
    exit 0
fi

STATE="${1:-idle}"
[ -z "${TMUX_PANE:-}" ] && exit 0

sweep_dead

WIN="$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)"
[ -z "$WIN" ] && exit 0

# 状态文件由 state.sh 负责写（含粘性逻辑），这里只做聚合
tmux set-option -w -t "$WIN" @claude_win_state "$(aggregate "$WIN")" 2>/dev/null || true
# 清理可能动到别的 window（会话是在自己那个 pane 里死掉的，而清理它的时机
# 只能是别处有 hook 触发），那些也要重算 —— 但只重算被动过的。
if [ -n "$SWEPT" ]; then
    OLDIFS="$IFS"; IFS=,
    for w in $SWEPT; do
        [ "$w" = "$WIN" ] && continue
        tmux set-option -w -t "$w" @claude_win_state "$(aggregate "$w")" 2>/dev/null || true
    done
    IFS="$OLDIFS"
fi
tmux refresh-client -S 2>/dev/null || true
exit 0
