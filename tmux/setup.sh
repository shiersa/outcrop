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
# 用法: setup.sh [--ascii] [--subshell] [--no-dir] [--dir-max N] [--dir-full]
#                [--no-title] [--title-max N] [--dry-run] [--uninstall]
#
set -uo pipefail

DRY_RUN=0; ASCII=0; SUBSHELL=0; UNINSTALL=0; DIR=1; DIR_MAX=18; DIR_FULLMODE=0
TITLE=1; TITLE_MAX=40
while [ $# -gt 0 ]; do
    case "${1}" in
        --ascii)     ASCII=1 ;;
        --subshell)  SUBSHELL=1 ;;
        --no-dir)    DIR=0 ;;
        --dir-max)   shift; DIR_MAX="${1:-18}" ;;
        --dir-full)  DIR_FULLMODE=1 ;;
        --no-title)  TITLE=0 ;;
        --title-max) shift; TITLE_MAX="${1:-40}" ;;
        --dry-run)   DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
    esac
    shift
done

case "${DIR_MAX}" in
    ''|*[!0-9]*) echo "✗ --dir-max 必须是正整数"; exit 1 ;;
esac
[ "${DIR_MAX}" -lt 4 ] && { echo "✗ --dir-max 至少 4"; exit 1; }
case "${TITLE_MAX}" in
    ''|*[!0-9]*) echo "✗ --title-max 必须是正整数"; exit 1 ;;
esac
[ "${TITLE_MAX}" -lt 8 ] && { echo "✗ --title-max 至少 8"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
HOOK_DIR="${HOME}/.config/claude-tmux"
WIN_SH="${HOOK_DIR}/win-state.sh"
ORIG_JSON="${HOOK_DIR}/orig-window-status.json"
TMUX_CONF="${HOME}/.tmux.conf"
BEGIN_MARK="# ===== outcrop BEGIN (managed by outcrop/tmux/setup.sh) ====="
END_MARK="# ===== outcrop END ====="

# 图标必须是「有笔画」的字符。曾经 busy/wait/done 三个是空串，格式串里只剩
# 一个带颜色的空格 —— 而空格没有笔画，只设前景色等于没设，于是 busy 和 done
# 在标签栏上完全不可见，跟 idle 分不出来。只有 wait 因为设了背景色才看得见
# （一个红块）。三个状态里两个白做。
#
# 用标准区符号而不是 Nerd Font 私有区：私有区字形在没装补丁字体的终端上是
# 豆腐块，比空白更糟。●✓· 这几个几乎所有字体都有。
if [ "${ASCII}" -eq 1 ]; then
    I_BUSY='*'; I_WAIT='!'; I_DONE='+'; I_HINT='o'; I_IDLE='-'; I_WIDLE=''; I_ELL='~'
else
    I_BUSY='●'; I_WAIT='!'; I_DONE='✓'; I_HINT='○'; I_IDLE='·'; I_WIDLE=''; I_ELL='…'
fi

# wait 用底色而不只是前景色：小图标在余光里太容易漏掉，而这是唯一不该错过
# 的状态。但底色用青不用红 —— 红色读作「出错了」，而 wait 的意思是「该你了」，
# 语义完全不同。真出错的时候 Claude 自己会说，不需要标签栏来喊。
#
# hint 只给前景色、不给底色：它是「闲着」，不需要你做任何事，
# 显著度必须明显低于 wait，否则又回到「什么都在喊」的老问题。
C_BUSY='#[fg=colour214]'
C_WAIT='#[fg=colour232#,bg=colour44#,bold]'
C_DONE='#[fg=colour114]'
C_HINT='#[fg=colour109]'
C_IDLE='#[fg=colour240]'
# 目录用中灰：既要比 window name 弱（它才是主体），又要在高亮的当前 tab
# 底色上读得出来。colour245 在两种底色下都够。
C_DIR='#[fg=colour245]'
# 标题（你输入的第一句）是边框上信息量最大的一段，比目录亮一档
C_TITLE='#[fg=colour252]'

if ! command -v tmux >/dev/null 2>&1; then
    echo "-  未找到 tmux，跳过 tmux 配置"
    exit 0
fi

remove_block() {
    [ -f "${TMUX_CONF}" ] || return 0
    [ "${DRY_RUN}" -eq 1 ] && { echo "   [dry-run] 移除 managed block"; return 0; }
    # 没有 block 就没什么可移除的，别为此留一份备份
    grep -qF "${BEGIN_MARK}" "${TMUX_CONF}" 2>/dev/null || return 0
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
# pane 边框也要备份。以前只存 window-status-*，卸载后运行中的 server 仍留着
# 本项目的 pane-border-format —— managed block 是从 .tmux.conf 里删掉了，
# 但活着的 server 不会因此回退，得重启 tmux 才干净。
TMUX_DEF_WSF='#I:#W#F'
TMUX_DEF_PBF='#{?pane_active,#[reverse],}#{pane_index}#[default] "#{pane_title}"'

orig_get() {  # orig_get <json key> <fallback>
    python3 -c 'import json,sys
try:    print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])
except Exception: print(sys.argv[3], end="")' "${ORIG_JSON}" "$1" "$2" 2>/dev/null || printf '%s' "$2"
}

WSF=""; WSCF=""; PBS=""; PBF=""
if [ -n "${TMUX:-}" ]; then
    WSF="$(tmux show-option -gv window-status-format 2>/dev/null || echo '')"
    WSCF="$(tmux show-option -gv window-status-current-format 2>/dev/null || echo '')"
    PBS="$(tmux show-option -gv pane-border-status 2>/dev/null || echo '')"
    PBF="$(tmux show-option -gv pane-border-format 2>/dev/null || echo '')"
fi
[ -z "${WSF}" ]  && WSF="${TMUX_DEF_WSF}"
[ -z "${WSCF}" ] && WSCF="${TMUX_DEF_WSF}"
[ -z "${PBS}" ]  && PBS='off'
[ -z "${PBF}" ]  && PBF="${TMUX_DEF_PBF}"

# 四个标记任一命中都算「已包过一层」。只认 claude_win_state 是不够的：
# --subshell 模式下图标走 win-state.sh 子进程，压根没这个串；目录段和
# pane 边框的 @claude_state 又各是一种形态。漏认的后果是重复运行套娃。
case "${WSF}${WSCF}${PBF}" in
    *claude_win_state*|*win-state.sh*|*'|~|:pane_current_path'*|*@claude_state*)
        if [ -f "${ORIG_JSON}" ]; then
            echo "   已包过一层，改用先前存下的原始值（避免套娃）"
            WSF="$(orig_get window-status-format "${TMUX_DEF_WSF}")"
            WSCF="$(orig_get window-status-current-format "${TMUX_DEF_WSF}")"
            # 老版本的备份里没有 pane 这两项，取不到就退回 tmux 默认
            PBS="$(orig_get pane-border-status off)"
            PBF="$(orig_get pane-border-format "${TMUX_DEF_PBF}")"
        else
            echo "   ⚠️  含本项目标记但找不到原始值备份，退回 tmux 默认"
            WSF="${TMUX_DEF_WSF}"; WSCF="${TMUX_DEF_WSF}"
            PBS='off'; PBF="${TMUX_DEF_PBF}"
        fi ;;
esac

if [ "${DRY_RUN}" -eq 0 ] && [ -n "${TMUX:-}" ]; then
    mkdir -p "${HOOK_DIR}"
    python3 - "${ORIG_JSON}" "${WSF}" "${WSCF}" "${PBS}" "${PBF}" <<'PYEOF'
import json, os, sys
path, wsf, wscf, pbs, pbf = sys.argv[1:6]
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"window-status-format": wsf, "window-status-current-format": wscf,
           "pane-border-status": pbs, "pane-border-format": pbf},
          open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PYEOF
    echo "   ✓ 原始主题存到 ${ORIG_JSON}"
fi

# --- 构造格式串 -----------------------------------------------------------
PANE_ICON="#{?#{==:#{@claude_state},busy},${C_BUSY}${I_BUSY}#[default],#{?#{==:#{@claude_state},wait},${C_WAIT}${I_WAIT}#[default],#{?#{==:#{@claude_state},done},${C_DONE}${I_DONE}#[default],#{?#{==:#{@claude_state},hint},${C_HINT}${I_HINT}#[default],${C_IDLE}${I_IDLE}#[default]}}}}"
PANE_FMT="${PANE_ICON} #{pane_index}:"

if [ "${SUBSHELL}" -eq 1 ]; then
    E="#(${WIN_SH} --read #{window_id})"
else
    E="#{@claude_win_state}"
fi
# 图标和窗口名之间只要一个空格。原主题多半以空格开头（" #I:#W "），
# 那就不再补 —— 否则 "● " + " 1:outcrop" 会挤出两个空格。
# 空格只加在有图标的分支里：idle 分支图标为空，补了会让那一格错位。
case "${WSF}" in
    ' '*) ICON_SEP='' ;;
    *)    ICON_SEP=' ' ;;
esac
WIN_ICON="#{?#{==:${E},busy},${C_BUSY}${I_BUSY}${ICON_SEP}#[default],#{?#{==:${E},wait},${C_WAIT}${I_WAIT}${ICON_SEP}#[default],#{?#{==:${E},done},${C_DONE}${I_DONE}${ICON_SEP}#[default],#{?#{==:${E},hint},${C_HINT}${I_HINT}${ICON_SEP}#[default],${I_WIDLE}}}}}"

# --- 目录段：标签栏和 pane 边框各自显示自己在哪 ---------------------------
#
# 纯 tmux 格式串算，不 fork 任何进程 —— 标签栏和 pane 边框都是每
# status-interval 秒重绘一次，这里塞个 #() 就是每 2 秒 × 每个 window/pane
# 一个子进程。
#
# 两步嵌套替换（内层先算）：
#   1. #{s|^#{HOME}|~|:pane_current_path}   /Users/x/PrivateProject/outcrop
#                                        -> ~/PrivateProject/outcrop
#   2. #{s|(\.?[^/])[^/]*/|\1/|:...}     每一级只留首字母，末级留全名
#                                        -> ~/P/outcrop
#
# 第 2 步的正则值得解释：匹配「若干非斜杠 + 一个斜杠」并只留首字母，斜杠一起
# 吃掉后从下一级继续扫，所以一次全局替换就能处理任意深度，不用循环。末级没有
# 尾随斜杠，匹配不到，因此完整保留 —— 这正是你要认的那个名字。
# 点目录多留一个字符（\.?），否则 ~/.config 和 ~/.local 都缩成 ~/. 无从分辨。
#
# 同一条链两处复用：在 window-status-format 里 pane_current_path 解析成该
# window 当前 pane 的路径（所以每个 tab 显示自己的目录），在 pane-border-format
# 里解析成该 pane 自己的路径（所以分屏后每块都显示自己的目录）。
DIR_FULL='#{s|(\.?[^/])[^/]*/|\1/|:#{s|^#{HOME}|~|:pane_current_path}}'

DIR_SEG=""; PD_FULL=""; PD_BASE=""
if [ "${DIR}" -eq 1 ]; then
    # 父路径：先取 dirname 再缩写。dirname 之后末级不再是「你要认的名字」，
    # 所以补一条 /(\.?[^/])[^/]*$ 把它也缩掉，~/PrivateProject 才会变成 ~/P。
    DIR_PARENT='#{s|/(\.?[^/])[^/]*$|/\1|:#{s|(\.?[^/])[^/]*/|\1/|:#{s|^#{HOME}|~|:#{d:pane_current_path}}}}'

    if [ "${DIR_FULLMODE}" -eq 1 ]; then
        DIR_PATH="${DIR_FULL}"
    else
        # 默认：末级和窗口名重复时只显示父路径。
        # 窗口名绝大多数时候就是目录 basename（tmux automatic-rename 的常见结果），
        # 这时 " 4:shiersa-ontology-site ~/P/shiersa-ontolo… " 里有 20 列在重复
        # 窗口名，真正的新信息只有 ~/P。省掉它，标签栏才装得下。
        # 你手动 rename 过、或 cd 到了别处，两者不等，自动退回完整路径。
        DIR_PATH="#{?#{==:#{b:pane_current_path},#{window_name}},${DIR_PARENT},${DIR_FULL}}"
        # $HOME 要短路掉：它的 basename 是你的用户名，窗口名恰好也叫用户名时
        # 会走进父路径分支，显示成 /U —— 纯噪音。家目录就该显示 ~。
        DIR_PATH="#{?#{==:#{pane_current_path},#{HOME}},~,${DIR_PATH}}"
    fi

    # 路径可能为空（pane 还没起来），空值时整段跳过，别留个孤零零的分隔符
    DIR_SEG="#{?pane_current_path,${C_DIR}#{=/${DIR_MAX}/${I_ELL}:${DIR_PATH}}#[default] ,}"

    # --- pane 边框上的目录段 ---------------------------------------------
    #
    # 分屏才是真正需要它的场合：标签栏只显示 window 当前 pane 的目录，
    # 一分屏另外几块就没地方看了。
    #
    # 这里不做「与窗口名重复就省略」那套 —— pane 边框上没有窗口名，不存在
    # 重复，每块都该显示完整路径。
    #
    # 但 pane 会窄。窄到装不下时 tmux 直接从右边硬切，切掉的正是末级那个
    # 你要认的名字（~/P/o/c/statusline 变成 ~/P/o/c/statu，看着还像个完整
    # 路径）。所以按 pane_width 分档主动降级，宁可少显示也不显示半截。
    #
    # 注意比较必须用 #{e|>=:a,b}（数值）。#{>=:a,b} 是字典序，"100" < "50"，
    # 宽 pane 反而会被判成窄的。
    PD_FULL=" ${C_DIR}#{=/${DIR_MAX}/${I_ELL}:${DIR_FULL}}#[default]"
    PD_BASE=" ${C_DIR}#{=/10/${I_ELL}:#{b:pane_current_path}}#[default]"
fi

# --- pane 标题：显示你最近输入的第一句，而不是进程名 ----------------------
#
# pane_current_command 对 Claude Code 毫无信息量 —— 它是 node，进程名还常被
# 显示成版本号（2.1.231）。有 @claude_prompt（hook 在 UserPromptSubmit 时写的）
# 就用它，没有才退回进程名，所以普通 shell 的 pane 行为完全不变。
#
# 宽度分档要连着目录段一起算：标题和目录抢的是同一条边框。有标题时窄 pane
# 直接不显示目录 —— 你要的是「这块在做什么」，目录标签栏上还有一份。
#
#   pane 宽度   有标题                        无标题（原样）
#   >= 宽档起点  标题 ≤TITLE_MAX + 完整目录     进程名 + 完整目录
#   >= 中档起点  标题 ≤20        + 完整目录     进程名 + 完整目录
#   >= 窄档起点  标题 ≤10        + 无目录       进程名 + 末级目录
#   <  窄档起点  标题 ≤8         + 无目录       进程名 + 无目录
#
# 各档起点是反算出来的，别写死。实测边框装饰恰好占 9 列
# （"── " + 图标 + " " + "N:" + 目录前的分隔空格 + 尾空格），
# 曾经按 8 估、把中档起点定在 46，结果 9+20+18=47 溢出 1 列，
# tmux 默默把目录末尾砍掉一个字符 —— 正是这套分档要防的事。
# DIR_MAX / TITLE_MAX 可调，所以起点必须跟着它们走。
OVH=10   # 装饰 9 列，留 1 列余量
DW=0; [ "${DIR}" -eq 1 ] && DW="${DIR_MAX}"

PB_CMD="#{pane_current_command}"
if [ "${DIR}" -eq 1 ]; then
    PB_CMD="${PB_CMD}#{?pane_current_path,#{?#{e|>=:#{pane_width},46},${PD_FULL},#{?#{e|>=:#{pane_width},20},${PD_BASE},}},}"
fi

if [ "${TITLE}" -eq 1 ]; then
    # 每档的标题上限不能超过总上限
    TT_MID=20;   [ "${TITLE_MAX}" -lt "${TT_MID}" ]    && TT_MID="${TITLE_MAX}"
    TT_NARROW=10;[ "${TITLE_MAX}" -lt "${TT_NARROW}" ] && TT_NARROW="${TITLE_MAX}"
    TT_TINY=8;   [ "${TITLE_MAX}" -lt "${TT_TINY}" ]   && TT_TINY="${TITLE_MAX}"

    TB_NARROW=$(( OVH + TT_NARROW ))
    TB_MID=$(( OVH + TT_MID + DW ))
    TB_WIDE=$(( OVH + TITLE_MAX + DW ))
    # TITLE_MAX 调得比 20 还小时宽档会掉到中档下面，档位顺序就乱了
    [ "${TB_WIDE}" -le "${TB_MID}" ] && TB_WIDE=$(( TB_MID + 1 ))

    T_WIDE="#{=/${TITLE_MAX}/${I_ELL}:#{@claude_prompt}}"
    T_MID="#{=/${TT_MID}/${I_ELL}:#{@claude_prompt}}"
    T_NARROW="#{=/${TT_NARROW}/${I_ELL}:#{@claude_prompt}}"
    T_TINY="#{=/${TT_TINY}/${I_ELL}:#{@claude_prompt}}"
    PB_TITLE="#{?#{e|>=:#{pane_width},${TB_WIDE}},${C_TITLE}${T_WIDE}#[default]${PD_FULL},#{?#{e|>=:#{pane_width},${TB_MID}},${C_TITLE}${T_MID}#[default]${PD_FULL},#{?#{e|>=:#{pane_width},${TB_NARROW}},${C_TITLE}${T_NARROW}#[default],${C_TITLE}${T_TINY}#[default]}}}"
    PANE_FMT="${PANE_FMT}#{?#{@claude_prompt},${PB_TITLE},${PB_CMD}}"
else
    PANE_FMT="${PANE_FMT}${PB_CMD}"
fi

# 原主题的 window-status-format 不一定以空格结尾，不补的话会和目录粘在一起
append_dir() {
    [ -z "${DIR_SEG}" ] && { printf '%s' "$1"; return; }
    case "$1" in
        *' ') printf '%s%s' "$1" "${DIR_SEG}" ;;
        *)    printf '%s %s' "$1" "${DIR_SEG}" ;;
    esac
}
WSF="$(append_dir "${WSF}")"
WSCF="$(append_dir "${WSCF}")"

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "   [dry-run] 会写入 managed block"
    exit 0
fi

# 备份不在这里做 —— 那时还不知道内容会不会变。下面两段 python 各自在真正
# 要落盘前才 cp，内容没变就什么都不留。早先无条件 cp 一份，于是每跑一次
# install.sh 就多一份 .tmux.conf.bak-*，全是同样的内容。
[ -f "${TMUX_CONF}" ] || touch "${TMUX_CONF}"

# 清掉 11/14/17 留下的旧 managed block。两套块共存时后出现的会覆盖先出现的，
# 表现为「改了配置没生效」，而且极难看出原因。
python3 - "${TMUX_CONF}" "${TS}" <<'CLEAN_EOF'
import os, shutil, sys
path, ts = sys.argv[1:3]
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
    shutil.copy2(path, "%s.bak-%s" % (path, ts))
    tmp = path + ".tmp"
    open(tmp, "w", encoding="utf-8").writelines(out)
    os.replace(tmp, path)
    for r in removed:
        print("   \u2713 \u5df2\u6e05\u7406\u65e7\u5757: %s" % r)
CLEAN_EOF

python3 - "${TMUX_CONF}" "${BEGIN_MARK}" "${END_MARK}" "${PANE_FMT}" "${WIN_ICON}" "${WSF}" "${WSCF}" "${TS}" <<'PYEOF'
import os, shutil, sys
path, begin, end, pane_fmt, icon, wsf, wscf, ts = sys.argv[1:9]

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

# 内容一模一样就别落盘，也别留备份。重复跑 install.sh 是常态，
# 每次都 cp 一份同样的内容出来，几十份 .bak 就是这么攒起来的。
if out == lines:
    print("   - managed block 无变化（未改动，不产生备份）")
    sys.exit(0)

shutil.copy2(path, "%s.bak-%s" % (path, ts))
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
