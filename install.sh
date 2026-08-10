#!/usr/bin/env bash
#
# outcrop 安装器。编译源码、部署 hooks、注册 statusLine。
# 幂等，已存在的配置不覆盖。
#
set -uo pipefail

echo "===== SCRIPT START ====="
echo

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
SL_DIR="${HOME}/.config/claude-statusline"
HOOK_DIR="${HOME}/.config/claude-tmux"
BIN="${SL_DIR}/claude-statusline"

run() { if [ "${DRY_RUN}" -eq 1 ]; then echo "   [dry-run] $*"; else eval "$@"; fi; }

CONFIG_DIRS=()
for d in "${HOME}"/.claude "${HOME}"/.claude-*; do
    [ -d "${d}" ] || continue
    case " ${CONFIG_DIRS[*]:-} " in
        *" ${d} "*) ;;
        *) CONFIG_DIRS+=("${d}") ;;
    esac
done

echo "===== 1. 前置检查 ====="
echo
command -v go >/dev/null 2>&1 \
    && echo "✓ Go: $(go version | awk '{print $3}')" \
    || { echo "✗ 未找到 go"; echo; echo "===== SCRIPT END ====="; exit 1; }
[ "${#CONFIG_DIRS[@]}" -gt 0 ] \
    && { echo "   配置目录:"; for d in "${CONFIG_DIRS[@]}"; do echo "   ✓ ${d}"; done; } \
    || { echo "✗ 没找到 Claude Code 配置目录"; echo; echo "===== SCRIPT END ====="; exit 1; }
echo

echo "===== 2. 编译 ====="
echo
run "mkdir -p '${SL_DIR}/cache' '${HOOK_DIR}'"
if [ "${DRY_RUN}" -eq 0 ]; then
    [ -f "${BIN}" ] && cp "${BIN}" "${BIN}.bak-${TS}"
    if ( cd "${ROOT}" && GOFLAGS=-mod=mod go build -ldflags="-s -w" -o "${BIN}" ./cmd/statusline ); then
        echo "✓ ${BIN} （$(ls -lh "${BIN}" | awk '{print $5}')，$(uname -m)）"
    else
        echo "✗ 编译失败"; echo; echo "===== SCRIPT END ====="; exit 1
    fi
else
    echo "   [dry-run] go build ./cmd/statusline"
fi
echo

echo "===== 3. 部署 hooks ====="
echo
for h in state.sh win-state.sh; do
    [ -f "${ROOT}/hooks/${h}" ] || continue
    run "cp '${ROOT}/hooks/${h}' '${HOOK_DIR}/${h}'"
    run "chmod 0755 '${HOOK_DIR}/${h}'"
    echo "✓ ${HOOK_DIR}/${h}"
done
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
    fi
done
echo

echo "===== 5. 注册 statusLine ====="
echo
if [ "${DRY_RUN}" -eq 0 ]; then
    for d in "${CONFIG_DIRS[@]}"; do
        [ -f "${d}/settings.json" ] && cp "${d}/settings.json" "${d}/settings.json.bak-${TS}"
        python3 - "${d}/settings.json" "${BIN}" <<'PYEOF' || echo "   ✗ ${d} 失败"
import json, os, sys
path, binary = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path, encoding="utf-8")) or {}
    except Exception as e:
        print("   ✗ 解析失败 %s (%s)" % (path, e)); sys.exit(1)
want = {"type": "command", "command": binary, "padding": 0}
if data.get("statusLine") == want:
    print("   - %s 已是最新" % path); sys.exit(0)
data["statusLine"] = want
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False); f.write("\n")
os.replace(tmp, path); os.chmod(path, 0o600)
print("   ✓ %s" % path)
PYEOF
    done
else
    echo "   [dry-run] 会把 statusLine 指向 ${BIN}"
fi
echo

echo "===== 6. 验证 ====="
echo
if [ "${DRY_RUN}" -eq 0 ]; then
    OUT="$(printf '%s' '{"model":{"id":"smoke","display_name":"smoke"},"transcript_path":"/nonexistent"}' | "${BIN}" 2>&1)"
    [ -n "${OUT}" ] && echo "✓ 冒烟测试通过" || echo "✗ 无输出"
    echo "   完整自检: ${BIN} --verify"
fi
echo
echo "✓ 完成"
echo
echo "===== SCRIPT END ====="
