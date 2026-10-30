```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# YAOF OpenWrt ImageBuilder
# OpenWrt 25.12.x
#
# 集成：
#   OpenClash
#   PassWall
#   PassWall 中文包
#
# 保留：
#   YAOF 自定义 feed
#   clean-overlay.sh
#   files overlay
#   profiles/packages.common
#   profiles/${PACKAGES_PROFILE}
#   x86 EFI 固件输出
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
SUBTARGET="${2:-}"
PROFILE="${3:-}"
PACKAGES_PROFILE="${4:-}"
REQUESTED_VERSION="${5:-25.12.6}"

if [[ -z "$TARGET" || -z "$SUBTARGET" || -z "$PROFILE" || -z "$PACKAGES_PROFILE" ]]; then
    echo "Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]" >&2
    exit 1
fi

log() {
    printf '[%s] %s\n' "$(date +'%T')" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

for cmd in curl tar sha256sum python3 awk sed grep sort find paste; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

# ------------------------------------------------------------
# OpenWrt 版本解析
# ------------------------------------------------------------

resolve_version() {
    local req="${1:-}"
    local versions
    local matched
    local escaped_req

    if [[ -z "$req" || "$req" == "latest" ]]; then
        req="25.12"
    fi

    log "Checking available OpenWrt releases..."

    versions="$(
        curl -fsSL --retry 3 \
            https://downloads.openwrt.org/releases/ |
        grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?/"' |
        sed 's/href="//;s/\///;s/"//' |
        grep -v 'rc' |
        sort -V
    )" || die "Cannot retrieve OpenWrt release list"

    [[ -n "$versions" ]] || die "OpenWrt release list is empty"

    if [[ "$req" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if printf '%s\n' "$versions" | grep -qxF "$req"; then
            printf '%s\n' "$req"
            return
        fi

        die "Requested OpenWrt release does not exist: $req"
    fi

    if [[ "$req" =~ ^[0-9]+\.[0-9]+$ ]]; then
        matched="$(
            printf '%s\n' "$versions" |
            grep -E "^${req//./\\.}\.[0-9]+$" |
            sort -V |
            tail -n 1
        )"

        [[ -n "$matched" ]] || die "No release found for $req"

        printf '%s\n' "$matched"
        return
    fi

    die "Invalid OpenWrt version: $req"
}

VERSION="$(resolve_version "$REQUESTED_VERSION")"

log "Using OpenWrt release: ${VERSION}"

# ------------------------------------------------------------
# 架构映射
# ------------------------------------------------------------

case "$TARGET" in
    x86)
        ARCH="x86_64"
        ;;
    rockchip)
        ARCH="aarch64_generic"
        ;;
    *)
        die "Unsupported target: ${TARGET}"
        ;;
esac

# ------------------------------------------------------------
# 目录
# ------------------------------------------------------------

WORK_DIR="${ROOT_DIR}/build_${TARGET}_${SUBTARGET}_${PROFILE}"
OUTPUT_DIR="${ROOT_DIR}/artifact"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

IB_NAME="openwrt-imagebuilder-${VERSION}-${TARGET}-${SUBTARGET}.Linux-x86_64"

IB_DIR="${WORK_DIR}/${IB_NAME}"

OVERLAY_DIR="${WORK_DIR}/overlay"

IB_REPOSITORIES="${IB_DIR}/repositories"

# ------------------------------------------------------------
# 下载 ImageBuilder
# ------------------------------------------------------------

if [[ ! -d "$IB_DIR" ]]; then

    IB_ARCHIVE="${WORK_DIR}/${IB_NAME}.tar.zst"

    IB_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.zst"

    log "Downloading ImageBuilder: ${IB_URL}"

    curl -fsSL --retry 3 --retry-delay 2 \
        "$IB_URL" \
        -o "$IB_ARCHIVE" ||
        die "Failed to download ImageBuilder archive"

    log "Extracting ImageBuilder..."

    tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR" ||
        die "Failed to extract ImageBuilder"

    rm -f "$IB_ARCHIVE"
fi

[[ -f "${IB_DIR}/Makefile" ]] ||
    die "ImageBuilder Makefile not found"

mkdir -p \
    "${IB_DIR}/keys" \
    "${IB_DIR}/packages"

# ------------------------------------------------------------
# YAOF 自定义 feed
# ------------------------------------------------------------

YAOF_KEY_URL="https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub"

YAOF_FEED_URL="https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb"

log "Fetching YAOF feed signing key..."

curl -fsSL --retry 3 --retry-delay 2 \
    "$YAOF_KEY_URL" \
    -o "${IB_DIR}/keys/custom-feed.rsa.pub" ||
    die "Failed to download YAOF signing key"

touch "$IB_REPOSITORIES"

if ! grep -qxF "$YAOF_FEED_URL" "$IB_REPOSITORIES"; then
    sed -i "1i ${YAOF_FEED_URL}" "$IB_REPOSITORIES"
fi

# ------------------------------------------------------------
# PassWall 软件源
# ------------------------------------------------------------

PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build"

PASSWALL_RELEASE="${VERSION%.*}"

PASSWALL_KEY_URL="${PASSWALL_BASE}/apk.pub"

PASSWALL_KEY="${IB_DIR}/keys/openwrt-passwall-build.pem"

PASSWALL_LUCI_FEED="${PASSWALL_BASE}/releases/packages-${PASSWALL_RELEASE}/${ARCH}/passwall_luci/packages.adb"

PASSWALL_CORE_FEED="${PASSWALL_BASE}/releases/packages-${PASSWALL_RELEASE}/${ARCH}/passwall_packages/packages.adb"

log "Configuring PassWall ${PASSWALL_RELEASE} feed..."

curl -fsSL --retry 3 --retry-delay 2 \
    "$PASSWALL_KEY_URL" \
    -o "$PASSWALL_KEY" ||
    die "Failed to download PassWall signing key"

for repo in "$PASSWALL_LUCI_FEED" "$PASSWALL_CORE_FEED"; do

    if ! grep -qxF "$repo" "$IB_REPOSITORIES"; then
        printf '%s\n' "$repo" >> "$IB_REPOSITORIES"
    fi

done

# ------------------------------------------------------------
# 创建 overlay
# ------------------------------------------------------------

rm -rf "$OVERLAY_DIR"

mkdir -p "$OVERLAY_DIR"

if [[ -d "${ROOT_DIR}/files" ]]; then
    log "Copying user overlay files..."
    cp -af "${ROOT_DIR}/files/." "$OVERLAY_DIR/"
fi

# ------------------------------------------------------------
# YAOF clean-overlay.sh
# 使用 YAOF 原始脚本中的真实地址
# ------------------------------------------------------------

mkdir -p "${OVERLAY_DIR}/usr/bin"

FUCK_URL="https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh"

log "Fetching fuck utility: ${FUCK_URL}"

curl -fsSL --retry 3 --retry-delay 2 \
    "$FUCK_URL" \
    -o "${OVERLAY_DIR}/usr/bin/fuck" ||
    die "Failed to download clean-overlay.sh"

chmod +x "${OVERLAY_DIR}/usr/bin/fuck"

# ------------------------------------------------------------
# Overlay APK 公钥
# ------------------------------------------------------------

mkdir -p "${OVERLAY_DIR}/etc/apk/keys"

cp -af \
    "${IB_DIR}/keys/custom-feed.rsa.pub" \
    "${OVERLAY_DIR}/etc/apk/keys/"

cp -af \
    "$PASSWALL_KEY" \
    "${OVERLAY_DIR}/etc/apk/keys/"

# ------------------------------------------------------------
# Overlay 自定义软件源
# ------------------------------------------------------------

mkdir -p "${OVERLAY_DIR}/etc/apk/repositories.d"

CUSTOM_FEEDS="${OVERLAY_DIR}/etc/apk/repositories.d/customfeeds.list"

touch "$CUSTOM_FEEDS"

for repo in \
    "$YAOF_FEED_URL" \
    "$PASSWALL_LUCI_FEED" \
    "$PASSWALL_CORE_FEED"
do

    if ! grep -qxF "$repo" "$CUSTOM_FEEDS"; then
        printf '%s\n' "$repo" >> "$CUSTOM_FEEDS"
    fi

done

# ------------------------------------------------------------
# Rockchip 架构配置
# ------------------------------------------------------------

if [[ "$TARGET" == "rockchip" ]]; then

    mkdir -p "${OVERLAY_DIR}/etc/apk"

    touch "${OVERLAY_DIR}/etc/apk/arch"

    if ! grep -qxF "aarch64_generic" "${OVERLAY_DIR}/etc/apk/arch"; then
        printf '%s\n' "aarch64_generic" \
            >> "${OVERLAY_DIR}/etc/apk/arch"
    fi

fi

# ------------------------------------------------------------
# OpenClash 最新正式版
# ------------------------------------------------------------

OPENCLASH_API="https://api.github.com/repos/vernesong/OpenClash/releases/latest"

log "Querying latest OpenClash stable release..."

OPENCLASH_INFO="$(
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$OPENCLASH_API" |
    python3 -c '
import json
import sys

data = json.load(sys.stdin)

if data.get("draft") or data.get("prerelease"):
    raise SystemExit("Latest OpenClash release is not stable")

assets = data.get("assets", [])

matches = [
    item for item in assets
    if item.get("name", "").startswith("luci-app-openclash-")
    and item.get("name", "").endswith(".apk")
]

if not matches:
    raise SystemExit("OpenClash APK not found")

asset = matches[0]
digest = asset.get("digest") or ""

if not digest.startswith("sha256:"):
    raise SystemExit("OpenClash SHA256 digest not found")

print(data.get("tag_name", ""))
print(asset.get("name", ""))
print(asset.get("browser_download_url", ""))
print(digest.split(":", 1)[1])
'
)" || die "Failed to obtain OpenClash release information"

OPENCLASH_TAG="$(printf '%s\n' "$OPENCLASH_INFO" | sed -n '1p')"

OPENCLASH_APK_NAME="$(printf '%s\n' "$OPENCLASH_INFO" | sed -n '2p')"

OPENCLASH_APK_URL="$(printf '%s\n' "$OPENCLASH_INFO" | sed -n '3p')"

OPENCLASH_EXPECTED_SHA256="$(printf '%s\n' "$OPENCLASH_INFO" | sed -n '4p')"

[[ -n "$OPENCLASH_TAG" ]] ||
    die "OpenClash release tag is empty"

[[ "$OPENCLASH_APK_NAME" == luci-app-openclash-*.apk ]] ||
    die "Invalid OpenClash APK filename"

log "OpenClash version: ${OPENCLASH_TAG}"

OPENCLASH_TEMP="${WORK_DIR}/${OPENCLASH_APK_NAME}"

curl -fL --retry 3 --retry-delay 2 \
    "$OPENCLASH_APK_URL" \
    -o "$OPENCLASH_TEMP" ||
    die "Failed to download OpenClash APK"

OPENCLASH_ACTUAL_SHA256="$(
    sha256sum "$OPENCLASH_TEMP" | awk '{print $1}'
)"

if [[ "$OPENCLASH_ACTUAL_SHA256" != "$OPENCLASH_EXPECTED_SHA256" ]]; then
    die "OpenClash APK SHA256 verification failed"
fi

log "OpenClash APK SHA256 verification passed"

# ------------------------------------------------------------
# OpenClash 本地 APK 包
#
# OpenWrt 25.12 ImageBuilder 会自动读取 packages/
# 并在构建时重新生成本地 APK 索引。
#
# 不运行 apk index。
# 不创建 file:// 仓库。
# ------------------------------------------------------------

log "Adding OpenClash APK to ImageBuilder packages..."

rm -f "${IB_DIR}/packages"/luci-app-openclash-*.apk

cp -f \
    "$OPENCLASH_TEMP" \
    "${IB_DIR}/packages/${OPENCLASH_APK_NAME}"

[[ -s "${IB_DIR}/packages/${OPENCLASH_APK_NAME}" ]] ||
    die "OpenClash APK copy failed"

log "OpenClash APK added to ImageBuilder packages"

# ------------------------------------------------------------
# 软件包清单读取
# ------------------------------------------------------------

load_packages() {
    local file="$1"

    [[ -f "$file" ]] ||
        die "Package profile not found: $file"

    sed \
        -e 's/\r$//' \
        -e 's/[[:space:]]*#.*$//' \
        "$file" |
    awk 'NF { print }'
}

COMMON_PROFILE="${ROOT_DIR}/profiles/packages.common"

USER_PROFILE="${ROOT_DIR}/profiles/${PACKAGES_PROFILE}"

[[ -f "$COMMON_PROFILE" ]] ||
    die "Common package profile not found: $COMMON_PROFILE"

[[ -f "$USER_PROFILE" ]] ||
    die "Selected package profile not found: $USER_PROFILE"

log "Loading common package profile..."

log "Loading selected package profile: ${PACKAGES_PROFILE}"

PACKAGES="$(
    {
        load_packages "$COMMON_PROFILE"
        load_packages "$USER_PROFILE"

        # 强制加入以下三个软件包
        printf '%s\n' \
            "luci-app-openclash" \
            "luci-app-passwall" \
            "luci-i18n-passwall-zh-cn"

    } |
    awk '!seen[$0]++' |
    paste -sd ' ' -
)"

[[ -n "$PACKAGES" ]] ||
    die "Package list is empty"

log "Requested packages:"

printf '%s\n' "$PACKAGES" | tr ' ' '\n' >&2

# ------------------------------------------------------------
# 清理旧构建产物
# ------------------------------------------------------------

BUILD_LOG="${WORK_DIR}/build.log"

IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"

rm -rf "$IB_BIN_DIR"

# ------------------------------------------------------------
# 构建固件
#
# 不再自动跳过缺失软件包。
# 任意强制软件包无法解析时，直接停止。
# ------------------------------------------------------------

log "Assembling firmware for ${PROFILE} (${VERSION})..."

make -C "$IB_DIR" image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES="$OVERLAY_DIR" \
    ROOTFS_PARTSIZE="1024" \
    2>&1 | tee "$BUILD_LOG" ||
    die "Firmware build failed. Check ${BUILD_LOG}"

# ------------------------------------------------------------
# 检查固件输出
# ------------------------------------------------------------

[[ -d "$IB_BIN_DIR" ]] ||
    die "Output directory not found: $IB_BIN_DIR"

DATE_STR="$(date +%Y-%m-%d)"

PLATFORM_LABEL="$(
    echo "$PROFILE" |
    sed 's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/'
)"

MATCH_PATTERN="*sysupgrade.img.gz"

if [[ "$TARGET" == "x86" ]]; then
    MATCH_PATTERN="*combined-efi.img.gz"
fi

mapfile -t IMAGE_FILES < <(
    find "$IB_BIN_DIR" \
        -type f \
        -name "$MATCH_PATTERN" |
    sort
)

[[ "${#IMAGE_FILES[@]}" -gt 0 ]] ||
    die "No firmware image found: ${MATCH_PATTERN}"

# ------------------------------------------------------------
# 复制固件
# ------------------------------------------------------------

for img in "${IMAGE_FILES[@]}"; do

    fname="$(basename "$img")"

    clean_suffix="$(
        echo "$fname" |
        sed -E "s/^openwrt-.*-${TARGET}-${SUBTARGET}-${PROFILE}-//"
    )"

    out_name="YAOF-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${clean_suffix}"

    cp -f "$img" "${OUTPUT_DIR}/${out_name}"

    log "Saved: ${out_name}"

done

# ------------------------------------------------------------
# 保存构建信息
# ------------------------------------------------------------

{
    echo "OpenWrt Version: ${VERSION}"
    echo "Target: ${TARGET}"
    echo "Subtarget: ${SUBTARGET}"
    echo "Profile: ${PROFILE}"
    echo "Architecture: ${ARCH}"
    echo "OpenClash: ${OPENCLASH_TAG}"
    echo "PassWall: luci-app-passwall"
    echo "PassWall Chinese: luci-i18n-passwall-zh-cn"
    echo "Packages Profile: ${PACKAGES_PROFILE}"
    echo "Build Date: ${DATE_STR}"
    echo
    echo "Requested Packages:"
    printf '%s\n' "$PACKAGES" | tr ' ' '\n'
} > "${OUTPUT_DIR}/build-info.txt"

log "Build completed successfully for ${PROFILE}."
log "Output directory: ${OUTPUT_DIR}"
```
