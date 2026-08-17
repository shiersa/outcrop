#!/usr/bin/env bash
#
# outcrop 发布打包：交叉编译 darwin universal 二进制，连同安装脚本和配置模板打成 tar.gz。
# 目标机器不需要 Go，也不需要这个仓库 —— 解压后直接 ./install.sh。
#
# 用法:
#   ./scripts/release.sh
#
# 产出:
#   dist/outcrop-<版本>-darwin-universal.tar.gz   （无 lipo 时是 -darwin-arm64）
#   dist/outcrop-<版本>-darwin-universal.tar.gz.sha256
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # scripts/ 的上级 = 仓库根
cd "${ROOT}"

# ---------------------------------------------------------------------------
# 版本号：git describe 优先（带 dirty 标注），没有就日期。
# ---------------------------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
   VERSION="$(git describe --tags --always --dirty 2>/dev/null)" &&
   [ -n "${VERSION}" ]; then
    :
else
    VERSION="dev-$(date +%Y%m%d)"
fi

# 工作区脏 → 警告：打出的包对应不了任何提交。
# （git describe --dirty 已在版本号里带了 -dirty，这里再提醒一次。）
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        echo "⚠️  工作区有未提交改动，打出的包对应不了任何提交（版本号 ${VERSION}）"
        echo
    fi
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

BIN_NAME="claude-statusline"
LDFLAGS="-s -w -X main.buildVersion=${VERSION}"

# ---------------------------------------------------------------------------
# 交叉编译。CGO_ENABLED=0 用纯 Go 解析器，免去交叉工具链，二进制也更可移植。
# ---------------------------------------------------------------------------
echo "===== 交叉编译（version=${VERSION}）====="
echo

build_arch() {
    local goarch="$1" out="$2"
    GOOS=darwin GOARCH="${goarch}" CGO_ENABLED=0 \
        go build -ldflags="${LDFLAGS}" -o "${out}" ./cmd/statusline
}

ARM="${TMPDIR}/${BIN_NAME}.arm64"
AMD="${TMPDIR}/${BIN_NAME}.amd64"
UNI="${TMPDIR}/${BIN_NAME}"
HAVE_ARM=0
HAVE_AMD=0

if build_arch arm64 "${ARM}"; then echo "✓ darwin/arm64"; HAVE_ARM=1; else echo "✗ darwin/arm64 失败"; fi
if build_arch amd64 "${AMD}"; then echo "✓ darwin/amd64"; HAVE_AMD=1; else echo "✗ darwin/amd64 失败"; fi
echo

if [ "${HAVE_ARM}" -eq 0 ]; then
    echo "✗ arm64 编译失败，无法继续"
    exit 1
fi

# lipo 合成 universal；没有 lipo 或 amd64 失败就只出 arm64，并诚实改名。
ARCH_TAG="universal"
if [ "${HAVE_AMD}" -eq 1 ] && command -v lipo >/dev/null 2>&1; then
    lipo -create -output "${UNI}" "${ARM}" "${AMD}"
    echo "✓ lipo 合成 universal（arm64 + amd64）"
else
    if ! command -v lipo >/dev/null 2>&1; then
        echo "⚠️  没有 lipo（装 Xcode Command Line Tools 即有），只出 arm64"
    else
        echo "⚠️  amd64 编译失败，只出 arm64"
    fi
    echo "   ⚠️  Intel Mac 上用不了这个包"
    cp "${ARM}" "${UNI}"
    ARCH_TAG="arm64"
fi
echo

# ---------------------------------------------------------------------------
# 收集文件。**只挑要进包的，cmd/ 和 go.mod 根本不拷，源码不会散出去。**
# ---------------------------------------------------------------------------
echo "===== 收集文件 ====="
echo
PKGDIR="${TMPDIR}/outcrop"
mkdir -p "${PKGDIR}"

cp "${UNI}" "${PKGDIR}/${BIN_NAME}"
chmod 0755 "${PKGDIR}/${BIN_NAME}"
cp "${ROOT}/install.sh"   "${PKGDIR}/install.sh"
cp "${ROOT}/uninstall.sh" "${PKGDIR}/uninstall.sh"
cp "${ROOT}/README.md"    "${PKGDIR}/README.md"
# 分发出去的包必须带许可，否则拿到包的人不知道能不能用
cp "${ROOT}/LICENSE"      "${PKGDIR}/LICENSE"

cp -R "${ROOT}/hooks"   "${PKGDIR}/hooks"
cp -R "${ROOT}/tmux"    "${PKGDIR}/tmux"
cp -R "${ROOT}/scripts" "${PKGDIR}/scripts"
mkdir -p "${PKGDIR}/config"
cp "${ROOT}"/config/*.example "${PKGDIR}/config/" 2>/dev/null || true

# 权限：脚本要能直接跑
chmod 0755 "${PKGDIR}"/install.sh "${PKGDIR}"/uninstall.sh 2>/dev/null || true
find "${PKGDIR}"/hooks "${PKGDIR}"/tmux "${PKGDIR}"/scripts -name '*.sh' \
    -exec chmod 0755 {} + 2>/dev/null || true

printf '%s\n' "${VERSION}" > "${PKGDIR}/VERSION"

echo "✓ 二进制 + 脚本 + hooks/tmux/scripts + config/*.example + LICENSE + VERSION"
echo

# 防御性核查：源码绝不进包。
LEAK="$(find "${PKGDIR}" \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) -print)"
if [ -n "${LEAK}" ]; then
    echo "✗ 打包目录里混入了 Go 源码，中止:"
    echo "${LEAK}"
    exit 1
fi
echo "✓ 无 .go / go.mod / go.sum"
echo

# ---------------------------------------------------------------------------
# 打包 + 校验和。
# ---------------------------------------------------------------------------
echo "===== 打包 ====="
echo
DIST="${ROOT}/dist"
mkdir -p "${DIST}"

# 先清掉上一版的产物。不清的话 dist/ 会跨版本堆积，发 Release 时
# `gh release create v1.1.0 dist/*` 会把 v1.0.0 的包一并传上去。
# 只删本脚本自己按固定命名产出的那几类，不是 dist/* 一把梭 ——
# 范围确定，也就不需要谁来替你判断这次删除安不安全。
rm -f "${DIST}"/outcrop-*-darwin-*.tar.gz \
      "${DIST}"/outcrop-*-darwin-*.tar.gz.sha256 \
      "${DIST}"/outcrop-*-darwin-*.sh \
      "${DIST}"/outcrop-*-darwin-*.sh.sha256
ARCHIVE_NAME="outcrop-${VERSION}-darwin-${ARCH_TAG}.tar.gz"
ARCHIVE="${DIST}/${ARCHIVE_NAME}"

# tar 用相对路径，包内顶层是 outcrop/。
tar -C "${TMPDIR}" -czf "${ARCHIVE}" outcrop

( cd "${DIST}" && shasum -a 256 "${ARCHIVE_NAME}" > "${ARCHIVE_NAME}.sha256" )

echo "✓ ${ARCHIVE} （$(ls -lh "${ARCHIVE}" | awk '{print $5}')）"
echo "✓ ${ARCHIVE}.sha256"
echo

# 自解压安装包：单文件，目标机器上一条命令搞定，且自带载荷校验
SELF_SH="${DIST}/outcrop-${VERSION}-darwin-${ARCH_TAG}.sh"
bash "${ROOT}/scripts/mkself.sh" "${ARCHIVE}" "${VERSION}" "${SELF_SH}"
( cd "${DIST}" && shasum -a 256 "$(basename "${SELF_SH}")" > "$(basename "${SELF_SH}").sha256" )
echo "✓ ${SELF_SH}.sha256"
echo

# 包内二进制架构，便于核对
echo "包内二进制架构: $(lipo -archs "${PKGDIR}/${BIN_NAME}" 2>/dev/null || echo "(lipo 不可用)")"
echo
echo "目标机器安装（推荐，单文件，自带校验）:"
echo "   bash $(basename "${SELF_SH}")"
echo "   bash $(basename "${SELF_SH}") --help    # 全部开关"
echo
echo "或者用 tar 包:"
echo "   shasum -a 256 -c ${ARCHIVE_NAME}.sha256"
echo "   tar xzf ${ARCHIVE_NAME}"
echo "   cd outcrop && ./install.sh"
