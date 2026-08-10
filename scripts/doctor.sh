#!/usr/bin/env bash
#
# outcrop/scripts/doctor.sh —— 完整性核查，只读
#
# 「装完整了」不该靠人记，这里逐项验证。任何一项 ✗ 都说明有东西没装到位。
#
set -uo pipefail

SL_DIR="${HOME}/.config/claude-statusline"
HOOK_DIR="${HOME}/.config/claude-tmux"
BIN="${SL_DIR}/claude-statusline"
TMUX_CONF="${HOME}/.tmux.conf"

PASS=0; FAIL=0; WARN=0
ok()   { echo "   ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "   ✗ $*"; FAIL=$((FAIL+1)); }
warn() { echo "   ⚠️  $*"; WARN=$((WARN+1)); }

echo "===== 1. statusline 二进制 ====="
echo
if [ -x "${BIN}" ]; then
    ok "${BIN}"
    OUT="$(printf '%s' '{"model":{"id":"d","display_name":"d"},"transcript_path":"/nonexistent"}' | "${BIN}" 2>&1)"
    [ -n "${OUT}" ] && ok "冒烟测试有输出" || bad "冒烟测试无输出"
    for sub in --verify --dump-input --probe-glm --calibrate; do
        "${BIN}" "${sub}" >/dev/null 2>&1 || true
    done
    ok "子命令可调用（--verify / --dump-input / --probe-glm / --calibrate）"
else
    bad "找不到可执行的 ${BIN}"
fi
echo

echo "===== 2. hook 脚本 ====="
echo
for h in state.sh win-state.sh; do
    f="${HOOK_DIR}/${h}"
    if [ -x "${f}" ]; then
        ok "${f}"
    else
        bad "${f} 缺失或不可执行"
        continue
    fi
    bash -n "${f}" 2>/dev/null && ok "  ${h} 语法通过" || bad "  ${h} 语法错误"
done
grep -q "STICKY_WAIT" "${HOOK_DIR}/state.sh" 2>/dev/null \
    && ok "  粘性 wait 已启用（Stop 不会把 wait 降级成 done）" \
    || bad "  缺少粘性 wait —— 需要你介入的窗口会显示成已完成"
grep -q "DONE_TTL" "${HOOK_DIR}/win-state.sh" 2>/dev/null \
    && ok "  done 超时褪色已启用" \
    || warn "  没有 done TTL，绿色会一直留着淹没真信号"
grep -q "tmux display-message -d" "${HOOK_DIR}/state.sh" 2>/dev/null \
    && warn "  state.sh 仍会发 tmux 消息，那会遮住整条标签栏" \
    || ok "  未使用 tmux display-message（不遮挡标签栏）"
echo

echo "===== 3. settings.json 注册 ====="
echo
python3 - <<'PYEOF'
import json, os
home = os.path.expanduser("~")
need = {"UserPromptSubmit", "Stop", "SessionEnd", "Notification",
        "PreToolUse", "PermissionRequest"}
dirs = [os.path.join(home, n) for n in sorted(os.listdir(home))
        if (n == ".claude" or n.startswith(".claude-")) and os.path.isdir(os.path.join(home, n))]
if not dirs:
    print("   ✗ 没找到 Claude Code 配置目录")
for d in dirs:
    p = os.path.join(d, "settings.json")
    if not os.path.exists(p):
        print("   ✗ %s 不存在" % p); continue
    try:
        data = json.load(open(p, encoding="utf-8")) or {}
    except Exception as e:
        print("   ✗ %s 解析失败 (%s)" % (p, e)); continue
    sl = data.get("statusLine")
    slok = isinstance(sl, dict) and "claude-statusline" in str(sl.get("command", ""))
    hooks = data.get("hooks") or {}
    have = {e for e in hooks
            if any("claude-tmux" in str(h.get("command", ""))
                   for x in hooks[e] if isinstance(x, dict)
                   for h in x.get("hooks", []) if isinstance(h, dict))}
    missing = need - have
    tag = os.path.basename(d)
    print("   %s %-20s statusLine=%s hooks=%d/%d" % (
        "✓" if (slok and not missing) else "✗", tag,
        "有" if slok else "无", len(need) - len(missing), len(need)))
    if missing:
        print("      缺少事件: %s" % ", ".join(sorted(missing)))
PYEOF
echo

echo "===== 4. tmux 配置 ====="
echo
if ! command -v tmux >/dev/null 2>&1; then
    warn "未安装 tmux，状态图标层不适用"
elif [ ! -f "${TMUX_CONF}" ]; then
    bad "找不到 ${TMUX_CONF}"
else
    grep -q "outcrop BEGIN" "${TMUX_CONF}" && ok "managed block 存在" || bad "managed block 缺失"
    grep -q "pane-border-status top" "${TMUX_CONF}" && ok "pane 边框已开" || bad "pane 边框未开"
    grep -q "claude_win_state" "${TMUX_CONF}" && ok "标签栏图标已配" || bad "标签栏图标未配"
    grep -q "allow-passthrough on" "${TMUX_CONF}" && ok "allow-passthrough 已开" || warn "allow-passthrough 未开"

    # 逗号转义：#[...] 里出现裸逗号会把 #{?a,b,c} 拆散
    BADCOMMA=0
    while IFS= read -r line; do
        case "${line}" in
            *pane-border-format*|*window-status-format*|*window-status-current-format*)
                printf '%s' "${line}" | grep -oE '#\[[^]]*\]' | while IFS= read -r st; do
                    case "${st}" in
                        *"#,"*) ;;
                        *,*) echo "__BAD__${st}" ;;
                    esac
                done ;;
        esac
    done < "${TMUX_CONF}" > /tmp/outcrop-doctor-comma.$$ 2>/dev/null
    if grep -q "__BAD__" /tmp/outcrop-doctor-comma.$$ 2>/dev/null; then
        bad "格式串里有未转义的逗号（会导致样式指令被当字面量打出来）:"
        sed 's/__BAD__/      /' /tmp/outcrop-doctor-comma.$$
        BADCOMMA=1
    else
        ok "格式串逗号转义正确"
    fi
    rm -f /tmp/outcrop-doctor-comma.$$ 2>/dev/null

    if [ -f "${HOOK_DIR}/orig-window-status.json" ]; then
        ok "原始 tmux 主题已备份（卸载可还原）"
    else
        warn "没有 orig-window-status.json，卸载时无法还原你原来的标签栏样式"
    fi

    if [ -n "${TMUX:-}" ]; then
        CW="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
        OLD="$(tmux show-option -wqv @claude_win_state 2>/dev/null || echo '')"
        tmux set-option -w -t "${CW}" @claude_win_state wait 2>/dev/null
        R="$(tmux display-message -p '#{E:window-status-current-format}' 2>/dev/null || echo '')"
        if [ -n "$(printf '%s' "${R}" | tr -d '[:space:]')" ]; then
            ok "标签栏能渲染出内容"
        else
            bad "标签栏渲染为空"
        fi
        case "${R}" in
            *"#[fg=colour231"*) ok "wait 走到了白字红底分支" ;;
            *) warn "wait 分支没渲染出预期配色（--ascii 模式下属正常）" ;;
        esac
        if [ -n "${OLD}" ]; then
            tmux set-option -w -t "${CW}" @claude_win_state "${OLD}" 2>/dev/null
        else
            tmux set-option -wu -t "${CW}" @claude_win_state 2>/dev/null
        fi
    else
        warn "不在 tmux 会话内，跳过渲染验证"
    fi
fi
echo

echo "===== 5. 配置文件 ====="
echo
for c in pricing.json context_windows.json display.json glm.json; do
    [ -f "${SL_DIR}/${c}" ] && ok "${c}" || warn "${c} 缺失（会用内置默认值）"
done
echo

echo "===== 结论 ====="
echo
echo "   通过 ${PASS}   警告 ${WARN}   失败 ${FAIL}"
echo
if [ "${FAIL}" -gt 0 ]; then
    echo "   有 ${FAIL} 项没装到位。重跑 ./install.sh，仍然失败就把上面的输出发出来。"
    exit 1
fi
[ "${WARN}" -gt 0 ] && echo "   警告项不影响主要功能，看上面说明决定要不要处理。"
echo "   核心链路完整。"
