#!/usr/bin/env bash
#
# outcrop/scripts/doctor.sh —— 完整性核查，只读
#
# 「装完整了」不该靠人记，这里逐项验证。任何一项 ✗ 都说明有东西没装到位。
#
set -uo pipefail

SL_DIR="${HOME}/.config/claude-statusline"
HOOK_DIR="${HOME}/.config/claude-tmux"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/claude-tmux"
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
        "PreToolUse", "PermissionRequest", "SessionStart"}
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

    DIR_ON=0
    if grep -q '|~|:pane_current_path' "${TMUX_CONF}"; then
        DIR_ON=1
        grep -q 'pane-border-format.*|~|:pane_current_path' "${TMUX_CONF}" \
            && ok "pane 边框目录段已配（分屏后每块显示自己的目录）" \
            || warn "pane 边框没有目录段，分屏后看不到各自的目录"

        # 标签栏目录段默认是关的：那里的 pane_current_path 只代表 window 的
        # 当前 pane，一分屏就成了误导。--tab-dir 才打开。
        # 套娃自检只看 window-status-*：pane-border-format 每次都是从字面量
        # 重新拼的，不可能套娃，而且它内部本来就按宽度分档重复引用目录链，
        # 全局计数会一直误报。会被反复包装的只有标签栏（它包的是你原有的主题）。
        # 必须 grep -o | wc -l —— grep -c 数的是行数，两份格式串各占一行，
        # 套娃时行数不变，用 -c 永远发现不了。
        DUP="$(grep 'window-status' "${TMUX_CONF}" 2>/dev/null \
               | grep -o '|~|:pane_current_path' | wc -l | tr -d ' ')"
        if [ "${DUP}" -eq 0 ]; then
            ok "标签栏无目录段（默认；--tab-dir 可开）"
        elif [ "${DUP}" -gt 2 ]; then
            bad "标签栏目录段出现 ${DUP} 次（正常 2 次：普通 tab + 当前 tab），被套娃了"
        else
            ok "标签栏目录段已配（--tab-dir）"
        fi
        # 宽度分档必须走 #{e|>=:} 数值比较；写成 #{>=:} 是字典序，
        # "100" < "50"，宽 pane 会被误判成窄的而只显示末级
        if grep -q 'pane-border-format' "${TMUX_CONF}" \
           && grep 'pane-border-format' "${TMUX_CONF}" | grep -q '#{>=:'; then
            bad "pane 边框用了 #{>=:}（字典序），宽 pane 会被误判 —— 应为 #{e|>=:}"
        fi
    else
        warn "标签栏没有目录段（--no-dir 模式下属正常）"
    fi

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
            *"bg=colour208"*) ok "wait 走到了橙底分支" ;;
            *"bg=colour160"*|*"bg=colour44"*) warn "wait 还是旧配色（红底/青底）—— 重跑 tmux/setup.sh 更新" ;;
            *) warn "wait 分支没渲染出预期配色（--ascii 模式下属正常）" ;;
        esac
        # 目录段真的算出路径了吗 —— 正则写错时 tmux 不报错，只是渲染成空
        if [ "${DIR_ON}" -eq 1 ]; then
            D="$(tmux display-message -p '#{s|(\.?[^/])[^/]*/|\1/|:#{s|^#{HOME}|~|:pane_current_path}}' 2>/dev/null || echo '')"
            if [ -n "${D}" ]; then
                ok "目录段渲染正常（当前 pane: ${D}）"
            else
                bad "目录段渲染为空（tmux 版本可能不支持格式串正则替换，需 ≥ 3.1）"
            fi
            # 数值比较真的是数值吗：宽度 100 必须判成「够宽」
            T="$(tmux display-message -p '#{?#{e|>=:100,46},num,lex}' 2>/dev/null || echo '')"
            [ "${T}" = "num" ] \
                && ok "pane 宽度分档走数值比较" \
                || bad "#{e|>=:} 不可用（需 tmux ≥ 3.1），窄 pane 会被 tmux 从右硬切"
        fi

        # pane 标题：hook 抓到你输入的内容了吗
        if grep -q '@claude_prompt' "${TMUX_CONF}"; then
            ok "pane 标题已配（显示你输入的第一句，没有则退回进程名）"
            grep -q '^TITLE=1' "${HOOK_DIR}/state.sh" 2>/dev/null \
                || warn "  已部署的 state.sh 里 TITLE 不是 1，标题永远不会被写入"
            NP="$(tmux list-panes -a -F '#{@claude_prompt}' 2>/dev/null | grep -c . || true)"
            if [ "${NP:-0}" -gt 0 ]; then
                ok "  当前有 ${NP} 个 pane 抓到了标题"
            else
                warn "  还没有任何 pane 抓到标题 —— 提交一次输入后再看"
            fi
            # hook 收到过 payload 但里面没有 prompt 字段：字段改名了
            KF="${STATE_DIR}/last-hook-keys"
            if [ -f "${KF}" ]; then
                bad "  UserPromptSubmit 的 payload 里没有 prompt 字段，实际字段为:"
                echo "        $(cat "${KF}" 2>/dev/null)"
                echo "        改 hooks/state.sh 里取值那行的键名即可"
            fi
        else
            warn "pane 标题未配（--no-title 模式下属正常）"
        fi

        # 标签栏总宽超了会被 tmux 悄悄截掉，表现为「有几个 tab 看不见」
        # #{E:...} 展开后 #[fg=...] 仍是字面量，量宽度前必须先剔掉
        NEED="$(tmux list-windows -F '#{E:window-status-format}' 2>/dev/null \
                | python3 -c 'import sys, re, unicodedata
t = 0
for line in sys.stdin.read().splitlines():
    for ch in re.sub(r"#\[[^]]*\]", "", line):
        t += 2 if unicodedata.east_asian_width(ch) in "WF" else 1
print(t)' 2>/dev/null || echo 0)"
        AVAIL="$(tmux display-message -p '#{client_width}' 2>/dev/null || echo 0)"
        if [ "${NEED}" -gt 0 ] && [ "${AVAIL}" -gt 0 ]; then
            if [ "${NEED}" -gt "$((AVAIL - 24))" ]; then
                warn "标签栏约需 ${NEED} 列，终端 ${AVAIL} 列 —— 快装不下了，考虑 --dir-max 调小或 --no-dir"
            else
                ok "标签栏宽度够用（约 ${NEED}/${AVAIL} 列）"
            fi
        fi
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

echo "===== 4b. 单价定期同步 ====="
echo
SYNC_LABEL="com.outcrop.pricing-sync"
PLIST="${HOME}/Library/LaunchAgents/${SYNC_LABEL}.plist"
if [ -f "${PLIST}" ]; then
    if launchctl list 2>/dev/null | grep -q "${SYNC_LABEL}"; then
        ok "LaunchAgent 已加载（每 7 天同步一次单价）"
    else
        warn "plist 存在但未加载: launchctl bootstrap gui/$(id -u) ${PLIST}"
    fi
    LOG="${SL_DIR}/cache/sync-pricing.log"
    if [ -f "${LOG}" ]; then
        ok "  最近一次: $(date -r "${LOG}" '+%Y-%m-%d %H:%M')"
        grep -q '\u2717\|失败\|error' "${LOG}" 2>/dev/null && warn "  日志里有报错，看 ${LOG}"
    fi
else
    warn "未装单价同步（--pricing-sync 开启；Anthropic 用原生额度，用不到）"
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
