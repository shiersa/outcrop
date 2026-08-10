#!/usr/bin/env bash
#
# outcrop/tmux/setup.sh —— 写入 tmux managed block
#
# 合并了原先 11（pane 边框）、14（window 标签栏）、22（逗号转义 + 配色）
# 三个脚本的 tmux 部分。
#
# 两个必须记住的坑：
#   1. #{?cond,a,b} 用逗号分参数，样式指令里的裸逗号会把条件表达式拆散，
#      所以 #[fg=x,bg=y,bold] 必须写成 #[fg=x#,bg=y#,bold]。
#   2. 包装 window-status-format 前要先把原值存下来，否则卸载时还原不回去；
#      重复运行还要能识别"已经包过一层"，不然会套娃。
#
# 用法: setup.sh [--ascii] [--subshell] [--dry-run] [--uninstall]
#
set -uo pipefail

DRY_RUN=0; ASCII=0; SUBSHELL=0; UNINSTALL=0
for a in "$@"; do
    case "${a}" in
        --ascii)     ASCII=1 ;;
        --subshell)  SUBSHELL=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
    esac
done

TS="$(date +%Y%m%d-%H%M%S)"
HOOK_DIR="${HOME}/.config/claude-tmux"
WIN_SH="${HOOK_DIR}/win-state.sh"
ORIG_JSON="${HOOK_DIR}/orig-window-status.json"
TMUX_CONF="${HOME}/.tmux.conf"
BEGIN_MARK="# ===== outcrop BEGIN (managed by outcrop/tmux/setup.sh) ====="
END_MARK="# ===== outcrop END ====="

if [ "${ASCII}" -eq 1 ]; then
    I_BUSY='*'; I_WAIT='!'; I_DONE='+'; I_IDLE='-'; I_WIDLE=''
else
    I_BUSY=''; I_WAIT=''; I_DONE=''; I_IDLE='󰧟'; I_WIDLE=''
fi

# wait 用白字红底：红色小图标在余光里太容易漏掉，而这是唯一不该错过的状态
C_BUSY='#[fg=colour214]'
C_WAIT='#[fg=colour231#,bg=colour160#,bold]'
C_DONE='#[fg=colour114]'
C_IDLE='#[fg=colour240]'

if ! command -v tmux >/dev/null 2>&1; then
    echo "-  未找到 tmux，跳过 tmux 配置"
    exit 0
fi

remove_block() {
    [ -f "${TMUX_CONF}" ] || return 0
    [ "${DRY_RUN}" -eq 1 ] && { echo "   [dry-run] 移除 managed block"; return 0; }
    cp "${TMUX_CONF}" "${TMUX_CONF}.bak-${TS}"
    python3 - "${TMUX_CONF}" "${BEGIN_MARK}" "${END_MARK}" <<'PYEOF'
import sys
path, begin, end = sys.argv[1:4]
lines = open(path, encoding="utf-8").readlines()
out, skip = [], False
for ln in lines:
    if ln.strip() == begin: skip = True; continue
    if ln.strip() == end:   skip = False; continue
    if not skip: out.append(ln)
while out and out[-1].strip() == "":
    out.pop()
out.append("\n")
open(path, "w", encoding="utf-8").writelines(out)
PYEOF
}

if [ "${UNINSTALL}" -eq 1 ]; then
    remove_block
    echo "✓ 已移除 tmux managed block"
    if [ -f "${ORIG_JSON}" ] && [ -n "${TMUX:-}" ] && [ "${DRY_RUN}" -eq 0 ]; then
        python3 - "${ORIG_JSON}" <<'PYEOF'
import json, subprocess, sys
for opt, val in json.load(open(sys.argv[1], encoding="utf-8")).items():
    subprocess.run(["tmux", "set-option", "-g", opt, val], check=False)
    print("   ✓ 已还原 %s" % opt)
PYEOF
        tmux source-file "${TMUX_CONF}" 2>/dev/null || true
    fi
    exit 0
fi

# --- 抓取原始主题 ---------------------------------------------------------
WSF=""; WSCF=""
if [ -n "${TMUX:-}" ]; then
    WSF="$(tmux show-option -gv window-status-format 2>/dev/null || echo '')"
    WSCF="$(tmux show-option -gv window-status-current-format 2>/dev/null || echo '')"
fi
[ -z "${WSF}" ]  && WSF='#I:#W#F'
[ -z "${WSCF}" ] && WSCF='#I:#W#F'

case "${WSF}${WSCF}" in
    *claude_win_state*)
        if [ -f "${ORIG_JSON}" ]; then
            echo "   已包过一层，改用先前存下的原始值（避免套娃）"
            WSF="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['window-status-format'])" "${ORIG_JSON}" 2>/dev/null || echo '#I:#W#F')"
            WSCF="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['window-status-current-format'])" "${ORIG_JSON}" 2>/dev/null || echo '#I:#W#F')"
        else
            echo "   ⚠️  含本项目标记但找不到原始值备份，退回 tmux 默认"
            WSF='#I:#W#F'; WSCF='#I:#W#F'
        fi ;;
esac

if [ "${DRY_RUN}" -eq 0 ] && [ -n "${TMUX:-}" ]; then
    mkdir -p "${HOOK_DIR}"
    python3 - "${ORIG_JSON}" "${WSF}" "${WSCF}" <<'PYEOF'
import json, os, sys
path, wsf, wscf = sys.argv[1:4]
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"window-status-format": wsf, "window-status-current-format": wscf},
          open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PYEOF
    echo "   ✓ 原始主题存到 ${ORIG_JSON}"
fi

# --- 构造格式串 -----------------------------------------------------------
PANE_FMT="#{?#{==:#{@claude_state},busy},${C_BUSY}${I_BUSY}#[default],#{?#{==:#{@claude_state},wait},${C_WAIT}${I_WAIT}#[default],#{?#{==:#{@claude_state},done},${C_DONE}${I_DONE}#[default],${C_IDLE}${I_IDLE}#[default]}}} #{pane_index}:#{pane_current_command}"

if [ "${SUBSHELL}" -eq 1 ]; then
    E="#(${WIN_SH} --read #{window_id})"
else
    E="#{@claude_win_state}"
fi
WIN_ICON="#{?#{==:${E},busy},${C_BUSY}${I_BUSY} #[default],#{?#{==:${E},wait},${C_WAIT}${I_WAIT} #[default],#{?#{==:${E},done},${C_DONE}${I_DONE} #[default],${I_WIDLE}}}}"

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "   [dry-run] 会写入 managed block"
    exit 0
fi

[ -f "${TMUX_CONF}" ] && cp "${TMUX_CONF}" "${TMUX_CONF}.bak-${TS}" || touch "${TMUX_CONF}"

# 清掉 11/14/17 留下的旧 managed block。两套块共存时后出现的会覆盖先出现的，
# 表现为「改了配置没生效」，而且极难看出原因。
python3 - "${TMUX_CONF}" <<'CLEAN_EOF'
import os, sys
path = sys.argv[1]
LEGACY = [
    ("# ===== claude-tmux-status BEGIN", "# ===== claude-tmux-status END"),
    ("# ===== claude-tmux-winstatus BEGIN", "# ===== claude-tmux-winstatus END"),
    ("# ===== claude-observability BEGIN", "# ===== claude-observability END"),
]
lines = open(path, encoding="utf-8").readlines()
out, skip, removed = [], None, []
for ln in lines:
    st = ln.strip()
    if skip is None:
        hit = None
        for b, e in LEGACY:
            if st.startswith(b):
                hit = e
                break
        if hit:
            skip = hit
            removed.append(st.split("(")[0].strip())
            continue
        out.append(ln)
    else:
        if st.startswith(skip):
            skip = None
        continue
while out and out[-1].strip() == "":
    out.pop()
out.append("\n")
if removed:
    tmp = path + ".tmp"
    open(tmp, "w", encoding="utf-8").writelines(out)
    os.replace(tmp, path)
    for r in removed:
        print("   \u2713 \u5df2\u6e05\u7406\u65e7\u5757: %s" % r)
CLEAN_EOF

python3 - "${TMUX_CONF}" "${BEGIN_MARK}" "${END_MARK}" "${PANE_FMT}" "${WIN_ICON}" "${WSF}" "${WSCF}" <<'PYEOF'
import os, sys
path, begin, end, pane_fmt, icon, wsf, wscf = sys.argv[1:8]

def q(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

block = [
    begin,
    "# pane 边框：单个 pane 的状态",
    "set -g pane-border-status top",
    'set -g pane-border-format " %s "' % q(pane_fmt),
    "set -g pane-border-style fg=colour238",
    "set -g pane-active-border-style fg=colour109",
    "# 标签栏：window 级聚合，切走了也看得见",
    "# 原始格式串存在 ~/.config/claude-tmux/orig-window-status.json",
    'set -g window-status-format "%s%s"' % (q(icon), q(wsf)),
    'set -g window-status-current-format "%s%s"' % (q(icon), q(wscf)),
    "set -g status-interval 2",
    "set -g allow-passthrough on",
    "set -g focus-events on",
    "set -g monitor-bell on",
    "set -g bell-action any",
    end,
]

lines = open(path, encoding="utf-8").readlines() if os.path.exists(path) else []
out, skip, replaced = [], False, False
for ln in lines:
    if ln.strip() == begin:
        skip = True; out.extend(x + "\n" for x in block); replaced = True; continue
    if ln.strip() == end:
        skip = False; continue
    if not skip:
        out.append(ln)
if not replaced:
    if out and not out[-1].endswith("\n"):
        out.append("\n")
    out.append("\n")
    out.extend(x + "\n" for x in block)
while out and out[-1].strip() == "":
    out.pop()
out.append("\n")

tmp = path + ".tmp"
open(tmp, "w", encoding="utf-8").writelines(out)
os.replace(tmp, path)
print("   ✓ managed block %s" % ("已更新" if replaced else "已追加"))
PYEOF

if [ -n "${TMUX:-}" ]; then
    tmux source-file "${TMUX_CONF}" 2>/dev/null \
        && echo "   ✓ 已重载 tmux 配置" \
        || echo "   ⚠️  重载失败，手动: tmux source-file ~/.tmux.conf"
fi
