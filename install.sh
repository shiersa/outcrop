#!/usr/bin/env bash
#
# outcrop 安装器 —— 编译、部署 hook、写 tmux 配置、注册 settings.json、核查。
# 幂等，已存在的配置不覆盖。
#
# 用法:
#   ./install.sh
#   ./install.sh --dry-run
#   ./install.sh --ascii            图标退成纯 ASCII（● ✓ · … 显示成方块时）
#   ./install.sh --subshell         标签栏改用子进程渲染
#   ./install.sh --no-tmux          只装 statusline
#   ./install.sh --no-notify        wait 时不发系统通知
#   ./install.sh --done-ttl 600     done 多久褪成 idle，0=不褪
#   ./install.sh --no-dir           pane 边框也不显示目录
#   ./install.sh --tab-dir          标签栏也显示目录（多 pane 时只代表当前那块）
#   ./install.sh --no-pane-count    标签栏不显示分屏块数
#   ./install.sh --no-session       不显示 session 名（跨会话通信寻址用的那个）
#   ./install.sh --session-max 12   session 名最多占几列（默认 16，保末尾截断）
#   ./install.sh --dir-max 12       目录段最多占几列（默认 28，超出保末尾截断）
#   ./install.sh --dir-full         目录段总是显示完整路径（默认与窗口名重复时省略末级）
#   ./install.sh --no-title         pane 边框仍显示进程名，不显示你输入的内容
#   ./install.sh --title-max 24     标题最多占几列（默认 40）
#   ./install.sh --yes              跳过交互菜单，直接按默认装
#   ./install.sh --pricing-sync     装一个每周同步单价的 LaunchAgent
#
# 不带任何配置开关、且在终端里运行时，会先弹一个勾选菜单。
#
set -uo pipefail

echo "===== SCRIPT START ====="
echo

DRY_RUN=0; ASCII=0; SUBSHELL=0; NO_TMUX=0; NOTIFY=1; DONE_TTL=900
NO_DIR=0; TAB_DIR=0; NO_PANE_CNT=0; DIR_MAX=28; DIR_FULL=0; NO_TITLE=0; TITLE_MAX=40
NO_SESS=0; SESS_MAX=16
NO_MENU=0; PRICING_SYNC=0

# 记下哪些是用户显式写的 —— 写了开关就说明他知道自己要什么，别再弹菜单打断
CONFIG_ARGS=0
for a in "$@"; do
    case "${a}" in
        --dry-run|-h|--help|--no-menu|--yes|-y) ;;
        --*) CONFIG_ARGS=1 ;;
    esac
done

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=1 ;;
        --ascii)     ASCII=1 ;;
        --subshell)  SUBSHELL=1 ;;
        --no-tmux)   NO_TMUX=1 ;;
        --no-notify) NOTIFY=0 ;;
        --done-ttl)  shift; DONE_TTL="${1:-900}" ;;
        --no-dir)    NO_DIR=1 ;;
        --tab-dir)   TAB_DIR=1 ;;
        --no-pane-count) NO_PANE_CNT=1 ;;
        --no-session) NO_SESS=1 ;;
        --session-max) shift; SESS_MAX="${1:-16}" ;;
        --dir-max)   shift; DIR_MAX="${1:-28}" ;;
        --dir-full)  DIR_FULL=1 ;;
        --no-title)  NO_TITLE=1 ;;
        --title-max) shift; TITLE_MAX="${1:-40}" ;;
        --no-menu|--yes|-y) NO_MENU=1 ;;
        --pricing-sync)     PRICING_SYNC=1 ;;
        -h|--help)   sed -n '2,26p' "$0"; echo "===== SCRIPT END ====="; exit 0 ;;
        *)           echo "⚠️  未知参数: $1 （已忽略）" ;;
    esac
    shift
done

# 交互菜单。只在终端里、且没写任何配置开关时弹 —— 管道里、CI 里、
# 已经写明开关的场合都必须安静走默认值，否则脚本化安装会卡死在没人按的菜单前。
MENU_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/menu.sh"
if [ "${NO_MENU}" -eq 0 ] && [ "${CONFIG_ARGS}" -eq 0 ] && [ -f "${MENU_SH}" ]; then
    # shellcheck source=scripts/menu.sh
    . "${MENU_SH}"
    if menu_supported; then
        if menu_run; then
            NO_TMUX=$((1 - TMUX_ON)); NO_DIR=$((1 - DIR_ON)); NO_TITLE=$((1 - TITLE_ON))
            PRICING_SYNC="${SYNC_PRICING}"
            echo
            echo "   已选: ./install.sh ${MENU_FLAGS:-（全部默认）}"
            echo
        else
            echo "===== SCRIPT END ====="; exit 0
        fi
    fi
fi

case "${DONE_TTL}" in
    ''|*[!0-9]*) echo "✗ --done-ttl 必须是非负整数"; echo; echo "===== SCRIPT END ====="; exit 1 ;;
esac
case "${DIR_MAX}" in
    ''|*[!0-9]*) echo "✗ --dir-max 必须是正整数"; echo; echo "===== SCRIPT END ====="; exit 1 ;;
esac
case "${TITLE_MAX}" in
    ''|*[!0-9]*) echo "✗ --title-max 必须是正整数"; echo; echo "===== SCRIPT END ====="; exit 1 ;;
esac
# hook 存进 tmux option 的上限要盖得住显示上限，否则 --title-max 调大也没料可显示
TITLE_STORE=120
[ "${TITLE_MAX}" -gt "${TITLE_STORE}" ] && TITLE_STORE=$((TITLE_MAX + 20))

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
SL_DIR="${HOME}/.config/claude-statusline"
HOOK_DIR="${HOME}/.config/claude-tmux"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/claude-tmux"
BIN="${SL_DIR}/claude-statusline"
TOOLS_DIR="${HOOK_DIR}/tools"
SYNC_LABEL="com.outcrop.pricing-sync"

# 两用：包根目录有可执行的 claude-statusline 就是发布包（直接 cp），否则现场编译。
PREBUILT=0
[ -x "${ROOT}/claude-statusline" ] && PREBUILT=1

run() { if [ "${DRY_RUN}" -eq 1 ]; then echo "   [dry-run] $*"; else eval "$@"; fi; }

echo "===== 1. 前置检查 ====="
echo
# Go 只在需要现场编译时才是硬依赖；发布包带了预编译二进制就不需要。
if [ "${PREBUILT}" -eq 1 ]; then
    echo "✓ 使用预编译二进制（发布包），无需 Go"
else
    command -v go >/dev/null 2>&1 \
        && echo "✓ Go: $(go version | awk '{print $3}')" \
        || { echo "✗ 未找到 go（macOS: brew install go）"; echo; echo "===== SCRIPT END ====="; exit 1; }
fi
command -v python3 >/dev/null 2>&1 \
    && echo "✓ python3: $(python3 -V 2>&1)" \
    || { echo "✗ 未找到 python3"; echo; echo "===== SCRIPT END ====="; exit 1; }
if [ "${NO_TMUX}" -eq 0 ] && command -v tmux >/dev/null 2>&1; then
    echo "✓ tmux: $(tmux -V | awk '{print $2}')"
    [ -z "${TMUX:-}" ] && echo "   ⚠️  不在 tmux 会话内 —— 读不到现有 window-status-format，标签栏部分会跳过"
elif [ "${NO_TMUX}" -eq 0 ]; then
    echo "⚠️  未找到 tmux，自动跳过状态图标层"
    NO_TMUX=1
fi
echo

if [ "${PREBUILT}" -eq 1 ]; then
    echo "===== 2. 部署二进制（预编译）====="
else
    echo "===== 2. 编译 ====="
fi
echo
run "mkdir -p '${SL_DIR}/cache' '${HOOK_DIR}' '${STATE_DIR}'"
# 二进制 5MB 一份，无条件备份最伤 —— 曾攒到 18 份 104MB，其中只有 6 种。
# 和 .tmux.conf / settings.json 一样：先比对，一样就既不备份也不覆盖。
if [ "${PREBUILT}" -eq 1 ]; then
    if [ "${DRY_RUN}" -eq 0 ]; then
        if [ -f "${BIN}" ] && cmp -s "${ROOT}/claude-statusline" "${BIN}"; then
            echo "-  ${BIN} 已是最新（未改动，不产生备份）"
        else
            [ -f "${BIN}" ] && cp "${BIN}" "${BIN}.bak-${TS}"
            cp "${ROOT}/claude-statusline" "${BIN}"
            chmod 0755 "${BIN}"
            # 没有代码签名，从网络传过去的二进制会被 macOS 隔离，
            # 运行时报"无法验证开发者"——cp 之后去掉隔离属性。
            xattr -dr com.apple.quarantine "${BIN}" 2>/dev/null || true
            ARCH="$(file "${BIN}" | grep -oE 'universal|arm64|x86_64' | head -1)"
            echo "✓ ${BIN} （$(ls -lh "${BIN}" | awk '{print $5}')，预编译 ${ARCH}）"
        fi
    else
        echo "   [dry-run] cp 预编译二进制 -> ${BIN}"
    fi
elif [ "${DRY_RUN}" -eq 0 ]; then
    # 先编到临时文件才知道结果和现有的一不一样。编失败时旧二进制没被碰过。
    NEWBIN="${BIN}.new-${TS}"
    if ( cd "${ROOT}" && GOFLAGS=-mod=mod go build -ldflags="-s -w" -o "${NEWBIN}" ./cmd/statusline ); then
        if [ -f "${BIN}" ] && cmp -s "${NEWBIN}" "${BIN}"; then
            rm -f "${NEWBIN}"
            echo "-  ${BIN} 已是最新（未改动，不产生备份）"
        else
            [ -f "${BIN}" ] && cp "${BIN}" "${BIN}.bak-${TS}"
            mv "${NEWBIN}" "${BIN}"
            chmod 0755 "${BIN}"
            echo "✓ ${BIN} （$(ls -lh "${BIN}" | awk '{print $5}')，$(uname -m)）"
        fi
    else
        rm -f "${NEWBIN}"
        echo "✗ 编译失败 —— 旧二进制仍在原位，statusline 不受影响"
        echo; echo "===== SCRIPT END ====="; exit 1
    fi
else
    echo "   [dry-run] go build ./cmd/statusline"
fi
echo

echo "===== 3. 部署 hook ====="
echo
if [ "${NO_TMUX}" -eq 1 ]; then
    echo "-  跳过（--no-tmux）"
else
    for h in state.sh win-state.sh; do
        [ -f "${ROOT}/hooks/${h}" ] || { echo "✗ 项目里缺 hooks/${h}"; continue; }
        if [ "${DRY_RUN}" -eq 0 ]; then
            # NOTIFY / DONE_TTL / TITLE 是部署时注入的，项目里那份是模板。
            # TITLE_STORE 是「存进 tmux option 的上限」，跟显示上限
            # （--title-max，由 tmux/setup.sh 用）是两码事，别混。
            sed -e "s/^NOTIFY=.*/NOTIFY=${NOTIFY}/" \
                -e "s/^DONE_TTL=.*/DONE_TTL=${DONE_TTL}/" \
                -e "s/^TITLE=.*/TITLE=$((1 - NO_TITLE))/" \
                -e "s/^TITLE_STORE=.*/TITLE_STORE=${TITLE_STORE}/" \
                -e "s/^TITLE_FILL=.*/TITLE_FILL=${TITLE_MAX}/" \
                "${ROOT}/hooks/${h}" > "${HOOK_DIR}/${h}"
            chmod 0755 "${HOOK_DIR}/${h}"
            bash -n "${HOOK_DIR}/${h}" || echo "   ✗ ${h} 语法错误"
        fi
        echo "✓ ${HOOK_DIR}/${h}"
    done
    echo "   通知=${NOTIFY}  done 褪色=${DONE_TTL}s  pane 标题=$((1 - NO_TITLE))"
fi
echo

# 卸载器和核查脚本要留在机器上 —— 自解压安装包装完就把临时目录删了，
# 不留一份的话这套东西以后既卸不掉也查不了。
# 目录结构照搬仓库布局，uninstall.sh 里的 ${ROOT}/tmux/setup.sh 才能解析到。
echo "===== 3b. 维护脚本 ====="
echo
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "   [dry-run] 部署 uninstall.sh / doctor.sh 到 ${TOOLS_DIR}"
else
    mkdir -p "${TOOLS_DIR}/tmux" "${TOOLS_DIR}/scripts"
    for rel in uninstall.sh tmux/setup.sh scripts/register.py scripts/doctor.sh; do
        if [ -f "${ROOT}/${rel}" ]; then
            # 内容一样就别动，免得每次安装都刷新时间戳
            cmp -s "${ROOT}/${rel}" "${TOOLS_DIR}/${rel}" 2>/dev/null \
                || cp "${ROOT}/${rel}" "${TOOLS_DIR}/${rel}"
            chmod 0755 "${TOOLS_DIR}/${rel}"
        else
            echo "   ⚠️  缺 ${rel}"
        fi
    done
    echo "✓ ${TOOLS_DIR}/"
    echo "   卸载: bash ${TOOLS_DIR}/uninstall.sh"
    echo "   核查: bash ${TOOLS_DIR}/scripts/doctor.sh"
fi
echo

echo "===== 4. 配置模板 ====="
echo
for c in pricing.json context_windows.json display.json glm.json; do
    if [ -f "${SL_DIR}/${c}" ]; then
        echo "-  ${c} 已存在，保留"
    elif [ -f "${ROOT}/config/${c}.example" ]; then
        run "cp '${ROOT}/config/${c}.example' '${SL_DIR}/${c}'"
        run "chmod 0600 '${SL_DIR}/${c}'"
        echo "✓ ${SL_DIR}/${c}"
    else
        echo "-  没有 ${c}.example，跳过（程序会用内置默认值）"
    fi
done
echo

echo "===== 5. 注册 settings.json ====="
echo
ARGS="--binary '${BIN}' --state '${HOOK_DIR}/state.sh' --win '${HOOK_DIR}/win-state.sh'"
[ "${DRY_RUN}" -eq 1 ] && ARGS="${ARGS} --dry-run"
eval "python3 '${ROOT}/scripts/register.py' ${ARGS}" || echo "   ✗ 注册失败"
echo

echo "===== 6. tmux 配置 ====="
echo
if [ "${NO_TMUX}" -eq 1 ]; then
    echo "-  跳过"
else
    TARGS=""
    [ "${ASCII}" -eq 1 ]    && TARGS="${TARGS} --ascii"
    [ "${SUBSHELL}" -eq 1 ] && TARGS="${TARGS} --subshell"
    [ "${DRY_RUN}" -eq 1 ]  && TARGS="${TARGS} --dry-run"
    [ "${NO_DIR}" -eq 1 ]   && TARGS="${TARGS} --no-dir"
    [ "${TAB_DIR}" -eq 1 ]  && TARGS="${TARGS} --tab-dir"
    [ "${NO_PANE_CNT}" -eq 1 ] && TARGS="${TARGS} --no-pane-count"
    [ "${NO_SESS}" -eq 1 ]  && TARGS="${TARGS} --no-session"
    [ "${DIR_FULL}" -eq 1 ] && TARGS="${TARGS} --dir-full"
    [ "${NO_TITLE}" -eq 1 ] && TARGS="${TARGS} --no-title"
    TARGS="${TARGS} --dir-max ${DIR_MAX} --title-max ${TITLE_MAX} --session-max ${SESS_MAX}"
    bash "${ROOT}/tmux/setup.sh" ${TARGS}
fi
echo

# 单价定期同步。第三方 provider（DeepSeek 之类）调价频繁，手填不现实；
# LiteLLM 那份社区价目表是实时的，让 launchd 每周拉一次就行。
# 不放进 statusline 的渲染路径 —— 那东西每次重绘都跑，不能带网络请求。
echo "===== 6b. 单价定期同步 ====="
echo
PLIST="${HOME}/Library/LaunchAgents/${SYNC_LABEL}.plist"
if [ "${PRICING_SYNC}" -eq 1 ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "   [dry-run] 写入 ${PLIST} 并加载"
    else
        mkdir -p "${HOME}/Library/LaunchAgents"
        cat > "${PLIST}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${SYNC_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN}</string>
    <string>--sync-pricing</string>
  </array>
  <!-- StartInterval 而不是 StartCalendarInterval：笔记本经常睡着，
       按日历排的任务错过就直接跳过，按间隔排的会在唤醒后补跑。 -->
  <key>StartInterval</key><integer>604800</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${SL_DIR}/cache/sync-pricing.log</string>
  <key>StandardErrorPath</key><string>${SL_DIR}/cache/sync-pricing.log</string>
</dict>
</plist>
PLIST_EOF
        launchctl bootout "gui/$(id -u)/${SYNC_LABEL}" 2>/dev/null || true
        if launchctl bootstrap "gui/$(id -u)" "${PLIST}" 2>/dev/null; then
            echo "✓ ${PLIST}"
            echo "   每 7 天从 LiteLLM 同步一次单价，日志在 ${SL_DIR}/cache/sync-pricing.log"
        else
            echo "⚠️  plist 已写入但加载失败，手动: launchctl bootstrap gui/$(id -u) ${PLIST}"
        fi
    fi
else
    echo "-  未启用（--pricing-sync 开启；只对 DeepSeek/OpenAI 这类需要估价的 provider 有意义）"
fi
echo

echo "===== 7. 完整性核查 ====="
echo
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "   [dry-run] 跳过"
else
    bash "${ROOT}/scripts/doctor.sh" || true
fi

echo
echo "✓ 完成"
echo
echo "===== SCRIPT END ====="
