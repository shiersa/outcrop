#!/usr/bin/env bash
#
# outcrop 卸载器。移除 tmux managed block、还原标签栏和 pane 边框、
# 清掉 settings.json 里的 statusLine 和 hook、删除已部署的 hook 脚本。
#
# 不会删 ~/.config/claude-statusline 下的配置和 cache —— 那里有你填过的东西。
#
set -uo pipefail

echo "===== SCRIPT START ====="
echo

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SL_DIR="${HOME}/.config/claude-statusline"
HOOK_DIR="${HOME}/.config/claude-tmux"
BIN="${SL_DIR}/claude-statusline"

run() { if [ "${DRY_RUN}" -eq 1 ]; then echo "   [dry-run] $*"; else eval "$@"; fi; }

echo "===== 1. tmux ====="
echo
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "   [dry-run] 移除 managed block 并还原主题"
else
    bash "${ROOT}/tmux/setup.sh" --uninstall
fi
echo

echo "===== 2. settings.json ====="
echo
ARGS="--binary '${BIN}' --state '${HOOK_DIR}/state.sh' --win '${HOOK_DIR}/win-state.sh' --remove"
[ "${DRY_RUN}" -eq 1 ] && ARGS="${ARGS} --dry-run"
eval "python3 '${ROOT}/scripts/register.py' ${ARGS}" || echo "   ✗ 清理失败"
echo

echo "===== 3. 单价定时同步 ====="
echo
SYNC_LABEL="com.outcrop.pricing-sync"
PLIST="${HOME}/Library/LaunchAgents/${SYNC_LABEL}.plist"
SYSD_UNIT="outcrop-pricing-sync"
SYSD_DIR="${HOME}/.config/systemd/user"
if [ -f "${PLIST}" ]; then
    run "launchctl bootout 'gui/$(id -u)/${SYNC_LABEL}' 2>/dev/null || true"
    run "rm -f '${PLIST}'"
    echo "✓ 已卸载（LaunchAgent）"
elif [ -f "${SYSD_DIR}/${SYSD_UNIT}.timer" ]; then
    # Linux 侧是 systemd user timer（install.sh 6b 装的）
    run "systemctl --user disable --now '${SYSD_UNIT}.timer' 2>/dev/null || true"
    run "rm -f '${SYSD_DIR}/${SYSD_UNIT}.timer' '${SYSD_DIR}/${SYSD_UNIT}.service'"
    run "systemctl --user daemon-reload 2>/dev/null || true"
    echo "✓ 已卸载（systemd timer）"
else
    echo "-  未安装"
fi
echo

echo "===== 4. hook 脚本 ====="
echo
run "rm -f '${HOOK_DIR}/state.sh' '${HOOK_DIR}/win-state.sh'"
echo "✓ 已移除"
echo

echo "===== 5. 保留的东西 ====="
echo
cat <<EOF
   以下没有删除，需要的话自己清理：

     ${BIN}
     ${SL_DIR}/            配置与 cache
     ${HOOK_DIR}/          原始 tmux 主题备份
     ~/.tmux.conf.bak-*    每次改动都留了带时间戳的备份

   彻底清干净:
     rm -rf ${SL_DIR} ${HOOK_DIR}
EOF

echo
echo "✓ 完成"
echo
echo "===== SCRIPT END ====="
