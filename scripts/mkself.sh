#!/usr/bin/env bash
#
# outcrop 自解压安装包：把 tar.gz 直接接在一段 shell 头部后面，产出单个 .sh。
# 目标机器上只要 `bash outcrop-<版本>.sh`，不用 tar、不用 cd、不用手动校验。
#
# 两个必须记住的坑：
#   1. 头部末尾必须有 exit，否则 bash 会继续去解析后面的二进制字节。
#   2. 分割点用 `awk '/^__ARCHIVE__$/{print NR+1}'` 算行号，不能写死 —— 头部
#      改一行，写死的行号就全错，而且错得很隐蔽（解出来的包看着像损坏）。
#
# 用法: mkself.sh <tar.gz 路径> <版本> <输出 .sh 路径>
#
set -uo pipefail

TARBALL="${1:?需要 tar.gz 路径}"
VERSION="${2:?需要版本号}"
OUT="${3:?需要输出路径}"

[ -f "${TARBALL}" ] || { echo "✗ 找不到 ${TARBALL}"; exit 1; }

# shasum 是 perl 脚本，macOS 自带；精简 Linux 常常只有 coreutils 的 sha256sum。
# 两头（打包机和目标机）都按这个顺序探测。
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

SUM="$(sha256_of "${TARBALL}")"
SIZE="$(wc -c < "${TARBALL}" | tr -d ' ')"

HEADER="$(mktemp)"
trap 'rm -f "${HEADER}"' EXIT

cat > "${HEADER}" <<HEADER_EOF
#!/usr/bin/env bash
#
# outcrop ${VERSION} 自解压安装包
#
# 用法:
#   bash \$(basename "\$0")                 按默认配置安装
#   bash \$(basename "\$0") --ascii         图标退成纯 ASCII
#   bash \$(basename "\$0") --help          全部开关
#   bash \$(basename "\$0") --extract-only  只解包，不安装
#
# 安装到 ~/.config/claude-statusline 和 ~/.config/claude-tmux，不需要 root。
#
set -uo pipefail

OUTCROP_VERSION="${VERSION}"
EXPECT_SUM="${SUM}"
EXPECT_SIZE="${SIZE}"
HEADER_EOF

cat >> "${HEADER}" <<'HEADER_EOF'

for a in "$@"; do
    case "${a}" in
        --version) echo "outcrop ${OUTCROP_VERSION}"; exit 0 ;;
    esac
done

command -v python3 >/dev/null 2>&1 \
    || { echo "✗ 需要 python3（macOS 自带；Linux: apt/dnf install python3）"; exit 1; }

# macOS 自带 shasum（perl），精简 Linux 常常只有 sha256sum（coreutils）
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

SELF="$0"
# 头部到哪一行结束是算出来的，不是写死的
ARCHIVE_LINE="$(awk '/^__ARCHIVE__$/ { print NR + 1; exit }' "${SELF}")"
[ -n "${ARCHIVE_LINE}" ] || { echo "✗ 安装包损坏：找不到载荷分割标记"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

tail -n +"${ARCHIVE_LINE}" "${SELF}" > "${TMP}/payload.tar.gz"

# 自校验，省掉手动 shasum -c 那一步
GOT_SIZE="$(wc -c < "${TMP}/payload.tar.gz" | tr -d ' ')"
GOT_SUM="$(sha256_of "${TMP}/payload.tar.gz")"
if [ "${GOT_SIZE}" != "${EXPECT_SIZE}" ] || [ "${GOT_SUM}" != "${EXPECT_SUM}" ]; then
    echo "✗ 载荷校验失败，安装包在传输中损坏了"
    echo "   期望 ${EXPECT_SIZE} 字节 / ${EXPECT_SUM}"
    echo "   实际 ${GOT_SIZE} 字节 / ${GOT_SUM}"
    exit 1
fi
echo "✓ 载荷校验通过（${EXPECT_SUM}）"

tar -C "${TMP}" -xzf "${TMP}/payload.tar.gz" \
    || { echo "✗ 解包失败"; exit 1; }
[ -d "${TMP}/outcrop" ] || { echo "✗ 解包内容不对"; exit 1; }

# 只解包：留在当前目录，供你自己看或改
for a in "$@"; do
    if [ "${a}" = "--extract-only" ]; then
        DEST="./outcrop-${OUTCROP_VERSION}"
        rm -rf "${DEST}"
        mv "${TMP}/outcrop" "${DEST}"
        echo "✓ 已解包到 ${DEST}（未安装）"
        exit 0
    fi
done

cd "${TMP}/outcrop" || exit 1
bash install.sh "$@"
RC=$?

# 临时目录会被 trap 清掉。卸载器和核查脚本由 install.sh 装进
# ~/.config/claude-tmux/tools/，所以这里删干净也不影响以后卸载。
exit "${RC}"
__ARCHIVE__
HEADER_EOF

cat "${HEADER}" "${TARBALL}" > "${OUT}"
chmod 0755 "${OUT}"

echo "✓ ${OUT} （$(ls -lh "${OUT}" | awk '{print $5}')）"
