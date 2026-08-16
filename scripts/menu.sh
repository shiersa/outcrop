#!/usr/bin/env bash
#
# outcrop 安装选项菜单。被 install.sh source，把选择结果写进 MENU_FLAGS。
#
# 只在「stdin 和 stdout 都是终端」且「没带任何配置开关」时才弹 —— 管道里、
# CI 里、已经明确写了开关的场合都必须安静地走默认值，否则脚本化安装会卡死
# 在一个没人按键的菜单前。
#
# 三个必须记住的坑：
#   1. 进 raw 模式前先 `stty -g` 存下原设置，并用 trap 还原。中途 Ctrl-C
#      而没还原的话，用户的终端会变成不回显、不换行的废状态。
#   2. 方向键是三个字节（ESC [ A）。只 read 一个字节的话，剩下的 "[A"
#      会被当成两次普通按键，表现为「按一下上键，光标乱跳」。
#   3. 重绘用「光标上移 N 行 + 逐行清到行尾」，N 必须是上次真实打印的行数。
#      写死行数的话，加一行选项就会留下残影。
#
set -uo pipefail

# ── 选项表 ────────────────────────────────────────────────────────────────
# 每项: 区段|类型|键名|标签|说明|最小|最大|步长
MENU_ITEMS=(
    "组件|head|||装哪几层|||"
    "组件|bool|TMUX_ON|tmux 状态图标|pane 边框和标签栏显示 Claude 在忙 / 等你介入|||"
    "组件|bool|DIR_ON|pane 边框显示目录|~/P/outcrop，分屏后每块各显各的|||"
    "组件|bool|TAB_DIR|标签栏也显示目录|多 pane 时只代表当前那块，容易误导，默认关|||"
    "组件|bool|TITLE_ON|边框显示你输入的内容|替代没信息量的进程名（zsh / 2.1.231）|||"
    "样式|head|||长什么样|||"
    "样式|bool|ASCII|图标退成纯 ASCII|● ✓ · … 显示成方块时才需要，一般不用勾|||"
    "样式|num|DIR_MAX|目录段宽度|超出保末尾截断（末级名字才是你要认的）|8|48|4"
    "样式|num|TITLE_MAX|标题宽度|超出按句子边界收窄|8|80|4"
    "行为|head|||怎么提醒你|||"
    "行为|bool|NOTIFY|需要你介入时发系统通知|这是唯一不该错过的状态|||"
    "行为|num|DONE_TTL|done 褪色秒数|跑完的绿色多久褪成灰，0 = 不褪|0|1800|300"
)

TMUX_ON=1; DIR_ON=1; TAB_DIR=0; TITLE_ON=1; ASCII=0
DIR_MAX=28; TITLE_MAX=40; NOTIFY=1; DONE_TTL=900

MENU_FLAGS=""

menu_supported() {
    [ -t 0 ] && [ -t 1 ] && command -v stty >/dev/null 2>&1
}

# 由选项反推等价命令行 —— 顺便让人学会开关名，下次可以直接带参数跑
menu_build_flags() {
    MENU_FLAGS=""
    [ "${TMUX_ON}" -eq 0 ]  && MENU_FLAGS="${MENU_FLAGS} --no-tmux"
    [ "${ASCII}" -eq 1 ]    && MENU_FLAGS="${MENU_FLAGS} --ascii"
    # --no-dir 连标签栏一起关，这时再给 --tab-dir 就是自相矛盾的命令行
    if [ "${DIR_ON}" -eq 0 ]; then
        MENU_FLAGS="${MENU_FLAGS} --no-dir"
    elif [ "${TAB_DIR}" -eq 1 ]; then
        MENU_FLAGS="${MENU_FLAGS} --tab-dir"
    fi
    [ "${TITLE_ON}" -eq 0 ] && MENU_FLAGS="${MENU_FLAGS} --no-title"
    [ "${DIR_MAX}" -ne 28 ]   && MENU_FLAGS="${MENU_FLAGS} --dir-max ${DIR_MAX}"
    [ "${TITLE_MAX}" -ne 40 ] && MENU_FLAGS="${MENU_FLAGS} --title-max ${TITLE_MAX}"
    [ "${NOTIFY}" -eq 0 ]   && MENU_FLAGS="${MENU_FLAGS} --no-notify"
    [ "${DONE_TTL}" -ne 900 ] && MENU_FLAGS="${MENU_FLAGS} --done-ttl ${DONE_TTL}"
    MENU_FLAGS="${MENU_FLAGS# }"
}

# 依赖关系：tmux 层关掉后，下面三项就没有意义了
menu_dimmed() {
    case "$1" in
        DIR_ON|TAB_DIR|TITLE_ON|ASCII|DIR_MAX|TITLE_MAX) [ "${TMUX_ON}" -eq 0 ] && return 0 ;;
    esac
    case "$1" in
        TAB_DIR|DIR_MAX) [ "${DIR_ON}" -eq 0 ] && return 0 ;;
        TITLE_MAX) [ "${TITLE_ON}" -eq 0 ] && return 0 ;;
    esac
    return 1
}

MENU_LINES=0

menu_draw() {
    local cur="$1" i=0 seg="" out=""
    local B=$'\033[1m' D=$'\033[2m' C=$'\033[36m' G=$'\033[32m' R=$'\033[0m'

    out+="  ${B}outcrop 安装选项${R}\n"
    out+="  ${D}↑↓ 移动   空格 开关   ←→ 改数值   回车 开始安装   q 取消${R}\n\n"

    for item in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r s type key label desc _min _max _step <<< "${item}"
        if [ "${type}" = "head" ]; then
            out+="  ${D}${desc}${R}\n"
            i=$((i + 1)); continue
        fi
        local mark ptr="  " dim=""
        menu_dimmed "${key}" && dim="${D}"
        [ "${i}" -eq "${cur}" ] && ptr="${C}▸${R} "
        if [ "${type}" = "bool" ]; then
            if [ "$(eval echo \$"${key}")" -eq 1 ]; then mark="${G}[✓]${R}"; else mark="${D}[ ]${R}"; fi
            out+="  ${ptr}${dim}${mark}${dim} ${label}${R}  ${D}${desc}${R}\n"
        else
            local v; v="$(eval echo \$"${key}")"
            out+="  ${ptr}${dim}    ${label}  ${B}${v}${R}${dim}  ${D}${desc}${R}\n"
        fi
        i=$((i + 1))
    done

    menu_build_flags
    out+="\n  ${D}等价命令: ${R}./install.sh ${MENU_FLAGS:-（全部默认）}\n"

    printf '%b' "${out}"
    MENU_LINES="$(printf '%b' "${out}" | wc -l | tr -d ' ')"
}

menu_redraw() {
    # 上移到上次绘制的起点，逐行清干净再重画
    printf '\033[%dA' "${MENU_LINES}"
    local n=0
    while [ "${n}" -lt "${MENU_LINES}" ]; do printf '\033[2K\033[1B'; n=$((n + 1)); done
    printf '\033[%dA' "${MENU_LINES}"
    menu_draw "$1"
}

menu_selectable() {  # 跳过区段标题
    local idx="$1" item
    item="${MENU_ITEMS[$idx]}"
    IFS='|' read -r _ type _ _ _ _ _ _ <<< "${item}"
    [ "${type}" != "head" ]
}

menu_run() {
    local cur=0 total="${#MENU_ITEMS[@]}"
    while [ "${cur}" -lt "${total}" ] && ! menu_selectable "${cur}"; do cur=$((cur + 1)); done

    local saved; saved="$(stty -g 2>/dev/null)" || return 1
    # 中途 Ctrl-C 也要把终端还回去，否则用户面对一个不回显的 shell
    trap 'stty "${saved}" 2>/dev/null; printf "\033[?25h\n"; exit 130' INT TERM
    stty -echo 2>/dev/null
    printf '\033[?25l'   # 藏光标，重绘时不闪

    menu_draw "${cur}"

    local key rest rest2 item type key_name mn mx st v
    while :; do
        IFS= read -rsn1 key 2>/dev/null || break
        if [ "${key}" = $'\033' ]; then
            # 方向键是三个字节 ESC [ B（应用光标模式下中间是 O，一并认了）。
            #
            # 超时必须写整数：macOS 自带的 bash 3.2 不接受小数，
            # `read -t 0.2` 直接报 "invalid timeout specification" 并立刻失败，
            # 于是 '[' 和 'B' 漏到下一轮被当成两次普通按键 —— 表现就是
            # 「方向键完全没反应」，而且报错信息还会把菜单画面冲花。
            rest=""; IFS= read -rsn2 -t 1 rest 2>/dev/null || rest=""
            case "${rest}" in
                '[A'|'OA') key=up ;;    '[B'|'OB') key=down ;;
                '[C'|'OC') key=right ;; '[D'|'OD') key=left ;;
                *) continue ;;
            esac
        fi

        item="${MENU_ITEMS[$cur]}"
        IFS='|' read -r _ type key_name _ _ mn mx st <<< "${item}"

        case "${key}" in
            up|k)
                local n="${cur}"
                while :; do
                    n=$((n - 1)); [ "${n}" -lt 0 ] && n=$((total - 1))
                    menu_selectable "${n}" && break
                done
                cur="${n}"; menu_redraw "${cur}" ;;
            down|j|$'\t')
                local n="${cur}"
                while :; do
                    n=$((n + 1)); [ "${n}" -ge "${total}" ] && n=0
                    menu_selectable "${n}" && break
                done
                cur="${n}"; menu_redraw "${cur}" ;;
            ' ')
                if [ "${type}" = "bool" ]; then
                    v="$(eval echo \$"${key_name}")"
                    eval "${key_name}=$((1 - v))"
                    menu_redraw "${cur}"
                fi ;;
            left|right|h|l)
                if [ "${type}" = "num" ]; then
                    v="$(eval echo \$"${key_name}")"
                    case "${key}" in
                        left|h)  v=$((v - st)); [ "${v}" -lt "${mn}" ] && v="${mn}" ;;
                        right|l) v=$((v + st)); [ "${v}" -gt "${mx}" ] && v="${mx}" ;;
                    esac
                    eval "${key_name}=${v}"
                    menu_redraw "${cur}"
                fi ;;
            ''|$'\n'|$'\r')
                stty "${saved}" 2>/dev/null; printf '\033[?25h'; trap - INT TERM
                menu_build_flags
                return 0 ;;
            q|Q)
                stty "${saved}" 2>/dev/null; printf '\033[?25h'; trap - INT TERM
                echo; echo "已取消，什么都没改。"
                return 1 ;;
        esac
    done
    stty "${saved}" 2>/dev/null; printf '\033[?25h'; trap - INT TERM
    menu_build_flags
    return 0
}
