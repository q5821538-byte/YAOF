#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# 基础配置
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
SUBTARGET="${2:-}"
PROFILE="${3:-}"
PACKAGES_PROFILE="${4:-}"
VERSION="${5:-}"

if [ -z "$TARGET" ] || [ -z "$SUBTARGET" ] || [ -z "$PROFILE" ] || [ -z "$PACKAGES_PROFILE" ]; then
    echo "Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]" >&2
    exit 1
fi

# 清理可能存在的 Windows CRLF
sed -i 's/\r$//' "${BASH_SOURCE[0]}"

log() {
    printf '[%s] %s\n' "$(date +'%T')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +'%T')" "$*" >&2
    exit 1
}

# ============================================================
# 版本识别
# ============================================================

resolve_version() {
    local req="${1:-}"
    local default_major="25.12"

    if [ -z "$req" ] || [ "$req" = "latest" ]; then
        req="$default_major"
    fi

    local versions

    versions=$(curl -fsSL --retry 3 \
        https://downloads.openwrt.org/releases/ 2>/dev/null |
        grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?/"' |
        sed 's/href="//;s/\///;s/"//' |
        sort -V || true)

    if [ -z "$versions" ]; then
        versions=$(git ls-remote --tags --refs \
            https://github.com/openwrt/openwrt.git 2>/dev/null |
            awk -F'/' '{print $NF}' |
            sed 's/^v//' || true)
    fi

    if echo "$versions" | grep -qx "$req"; then
        echo "$req"
        return
    fi

    local matched
    local escaped_req="${req//./\\.}"

    matched=$(echo "$versions" |
        grep -E "^${escaped_req}\.[0-9]+" |
        grep -v 'rc' |
        sort -V |
        tail -n 1 || true)

    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    matched=$(echo "$versions" |
        grep -E "^${escaped_req}" |
        grep -v 'rc' |
        sort -V |
        tail -n 1 || true)

    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    echo "${req:-25.12.6}"
}

VERSION=$(resolve_version "$VERSION")
log "Using OpenWrt release: ${VERSION}"

# ============================================================
# 架构识别
# ============================================================

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

WORK_DIR="${ROOT_DIR}/build_${TARGET}_${SUBTARGET}_${PROFILE}"
OUTPUT_DIR="${ROOT_DIR}/artifact"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

IB_NAME="openwrt-imagebuilder-${VERSION}-${TARGET}-${SUBTARGET}.Linux-x86_64"
IB_DIR="${WORK_DIR}/${IB_NAME}"

# ============================================================
# 下载 ImageBuilder
# ============================================================

if [ ! -d "$IB_DIR" ]; then
    IB_ARCHIVE="${WORK_DIR}/${IB_NAME}.tar.zst"

    IB_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.zst"

    log "Downloading ImageBuilder: ${IB_URL}"

    curl -fsSL --retry 3 --retry-delay 2 \
        "$IB_URL" -o "$IB_ARCHIVE" ||
        die "Failed to download ImageBuilder archive"

    tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR"

    rm -f "$IB_ARCHIVE"
fi

[ -d "$IB_DIR" ] || die "ImageBuilder directory not found"

mkdir -p "${IB_DIR}/keys"

# ============================================================
# YAOF 自定义软件源
# ============================================================

KEY_URL="https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub"

log "Fetching YAOF feed signing key: ${KEY_URL}"

curl -fsSL --retry 3 --retry-delay 2 \
    "$KEY_URL" \
    -o "${IB_DIR}/keys/custom-feed.rsa.pub" ||
    die "Failed to download YAOF feed signing key"

FEED_URL="https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb"

if ! grep -qxF "$FEED_URL" "${IB_DIR}/repositories"; then
    sed -i "1i ${FEED_URL}" "${IB_DIR}/repositories"
fi

# ============================================================
# PassWall 软件源
# 注意：源地址、密钥及软件包分类需要与实际仓库匹配
# ============================================================

PASSWALL_RELEASE="${VERSION%.*}"

PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PASSWALL_RELEASE}/${ARCH}"

PASSWALL_KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub"

PASSWALL_KEY="${IB_DIR}/keys/openwrt-passwall-build.pem"

log "Fetching PassWall signing key: ${PASSWALL_KEY_URL}"

curl -fsSL --retry 3 --retry-delay 2 \
    "$PASSWALL_KEY_URL" \
    -o "$PASSWALL_KEY" ||
    die "Failed to download PassWall signing key"

PASSWALL_FEEDS="
${PASSWALL_BASE}/passwall_luci/packages.adb
${PASSWALL_BASE}/passwall_packages/packages.adb
${PASSWALL_BASE}/passwall2/packages.adb
"

while IFS= read -r feed; do
    [ -n "$feed" ] || continue

    if ! grep -qxF "$feed" "${IB_DIR}/repositories"; then
        echo "$feed" >> "${IB_DIR}/repositories"
    fi
done <<< "$PASSWALL_FEEDS"

# ============================================================
# Overlay 文件
# ============================================================

OVERLAY_DIR="${WORK_DIR}/overlay"

rm -rf "$OVERLAY_DIR"
mkdir -p "$OVERLAY_DIR"

if [ -d "${ROOT_DIR}/files" ]; then
    cp -af "${ROOT_DIR}/files/." "$OVERLAY_DIR/"
fi

mkdir -p "${OVERLAY_DIR}/usr/bin"

FUCK_URL="https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh"

log "Fetching fuck utility: ${FUCK_URL}"

curl -fsSL --retry 3 --retry-delay 2 \
    "$FUCK_URL" \
    -o "${OVERLAY_DIR}/usr/bin/fuck" ||
    die "Failed to download clean-overlay.sh"

chmod +x "${OVERLAY_DIR}/usr/bin/fuck"

# ============================================================
# APK 签名密钥
# ============================================================

mkdir -p "${OVERLAY_DIR}/etc/apk/keys"

cp -af "${IB_DIR}/keys/custom-feed.rsa.pub" \
    "${OVERLAY_DIR}/etc/apk/keys/"

cp -af "$PASSWALL_KEY" \
    "${OVERLAY_DIR}/etc/apk/keys/"

# ============================================================
# APK 软件源
# ============================================================

mkdir -p "${OVERLAY_DIR}/etc/apk/repositories.d"

{
    echo "$FEED_URL"
    echo "${PASSWALL_BASE}/passwall_luci/packages.adb"
    echo "${PASSWALL_BASE}/passwall_packages/packages.adb"
    echo "${PASSWALL_BASE}/passwall2/packages.adb"
} > "${OVERLAY_DIR}/etc/apk/repositories.d/customfeeds.list"

if [ "$TARGET" = "rockchip" ]; then
    mkdir -p "${OVERLAY_DIR}/etc/apk"

    if ! grep -qxF "aarch64_generic" "${OVERLAY_DIR}/etc/apk/arch" 2>/dev/null; then
        echo "aarch64_generic" >> "${OVERLAY_DIR}/etc/apk/arch"
    fi
fi

# ============================================================
# 软件包配置
# ============================================================

load_packages() {
    local file="$1"

    [ -f "$file" ] || die "Package profile not found: $file"

    sed 's/\r$//' "$file" |
        grep -v '^[[:space:]]*#' |
        grep -v '^[[:space:]]*$' |
        tr '\n' ' ' || true
}

COMMON_PACKAGES="$(load_packages "${ROOT_DIR}/profiles/packages.common")"

PROFILE_PACKAGES="$(load_packages "${ROOT_DIR}/profiles/${PACKAGES_PROFILE}")"

PACKAGES="${COMMON_PACKAGES} ${PROFILE_PACKAGES}"

# ============================================================
# OpenClash
# ============================================================

OPENCLASH_REQUIRED="
luci-app-openclash
"

OPENCLASH_DEPS="
bash
curl
ca-bundle
ruby
ruby-yaml
dnsmasq-full
ip-full
ipset
unzip
kmod-tun
kmod-inet-diag
kmod-nft-tproxy
luci-compat
"

# ============================================================
# PassWall
# ============================================================

PASSWALL_REQUIRED="
luci-app-passwall
"

PASSWALL_DEPS="
coreutils
coreutils-base64
coreutils-nohup
coreutils-timeout
curl
chinadns-ng
dns2socks
dnsmasq-full
ip-full
libuci-lua
lua
luci-compat
luci-lib-jsonc
microsocks
resolveip
tcping
lyaml
"

# ============================================================
# PassWall NFT 依赖
# ============================================================

PASSWALL_NFT_DEPS="
ipt2socks
nftables
kmod-nft-socket
kmod-nft-tproxy
kmod-nft-nat
kmod-nf-reject
kmod-nf-reject6
"

# ============================================================
# PassWall 可选核心及组件
# ============================================================

PASSWALL_CORES="
geoview
smartdns
haproxy
shadowsocks-rust-sslocal
shadowsocksr-libev-ssr-local
shadowsocksr-libev-ssr-redir
simple-obfs-client
sing-box
v2ray-plugin
xray-core
unzip
"

# ============================================================
# 中文语言包
# ============================================================

PROXY_TRANSLATIONS="
luci-i18n-openclash-zh-cn
luci-i18n-passwall-zh-cn
"

# ============================================================
# 必须安装的插件及依赖
# ============================================================

PROXY_REQUIRED="
${OPENCLASH_REQUIRED}
${PASSWALL_REQUIRED}
${OPENCLASH_DEPS}
${PASSWALL_DEPS}
${PASSWALL_NFT_DEPS}
"

# 合并软件包
PACKAGES="${PACKAGES} ${PROXY_REQUIRED} ${PASSWALL_CORES} ${PROXY_TRANSLATIONS}"

# 去除重复包名
PACKAGES="$(printf '%s\n' $PACKAGES | awk 'NF && !seen[$0]++' | tr '\n' ' ')"

BUILD_LOG="${WORK_DIR}/build.log"

SKIPPED_PACKAGES=""

MAX_SKIP_ROUNDS=5

# ============================================================
# 固件构建
# ============================================================

build_firmware() {
    local packages="$1"

    log "Starting ImageBuilder..."

    # 避免 make 将软件包参数中的特殊字符错误解释
    make -C "$IB_DIR" image \
        "PROFILE=${PROFILE}" \
        "PACKAGES=${packages}" \
        "FILES=${OVERLAY_DIR}" \
        "ROOTFS_PARTSIZE=1024" \
        2>&1 | tee "$BUILD_LOG"
}

# ============================================================
# 检测缺失软件包
# ============================================================

missing_packages_from_log() {
    local log_file="$1"

    # APK: package (no such package):
    sed -nE \
        's/^[[:space:]]*([^ ]+) \(no such package\):[[:space:]]*$/\1/p' \
        "$log_file"

    # opkg: Cannot install package package-name.
    sed -nE \
        's/.*opkg_install_cmd: Cannot install package ([^ ]+)\.$/\1/p' \
        "$log_file"
}

# ============================================================
# 构建循环
# ============================================================

log "Assembling firmware for ${PROFILE} (${VERSION})..."

skip_round=0

while :; do

    if build_firmware "$PACKAGES"; then
        break
    fi

    missing="$(missing_packages_from_log "$BUILD_LOG" | sort -u)"

    kept=""
    skipped=""

    for pkg in $PACKAGES; do

        if printf '%s\n' "$missing" | grep -qxF -- "$pkg"; then
            skipped="${skipped}${skipped:+ }${pkg}"
        else
            kept="${kept}${kept:+ }${pkg}"
        fi

    done

    if [ -z "$skipped" ]; then
        die "Firmware build failed (no unavailable package detected). See ${BUILD_LOG}"
    fi

    # OpenClash、PassWall 及必要依赖不允许自动跳过
    for required_pkg in $PROXY_REQUIRED; do

        if printf '%s\n' "$skipped" | grep -qxF -- "$required_pkg"; then
            die "Required proxy package unavailable: ${required_pkg}. Check APK feeds and dependencies. See ${BUILD_LOG}"
        fi

    done

    skip_round=$((skip_round + 1))

    if [ "$skip_round" -gt "$MAX_SKIP_ROUNDS" ]; then
        die "Too many unavailable packages; last skipped: ${skipped}. See ${BUILD_LOG}"
    fi

    log "WARNING: Optional package(s) not available, skipping: ${skipped}"

    SKIPPED_PACKAGES="${SKIPPED_PACKAGES}${SKIPPED_PACKAGES:+ }${skipped}"

    PACKAGES="$kept"

done

if [ -n "$SKIPPED_PACKAGES" ]; then
    log "WARNING: Firmware built without optional package(s): ${SKIPPED_PACKAGES}"
fi

# ============================================================
# 复制固件
# ============================================================

IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"

[ -d "$IB_BIN_DIR" ] ||
    die "Output directory not found: $IB_BIN_DIR"

DATE_STR="$(date +%Y-%m-%d)"

PLATFORM_LABEL="$(echo "$PROFILE" |
    sed 's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/')"

MATCH_PATTERN="*sysupgrade.img.gz"

if [ "$TARGET" = "x86" ]; then
    MATCH_PATTERN="*combined-efi.img.gz"
fi

FOUND_IMAGE=0

while IFS= read -r -d '' img; do

    FOUND_IMAGE=1

    fname="$(basename "$img")"

    clean_suffix="$(echo "$fname" |
        sed -E "s/^openwrt-.*-${TARGET}-${SUBTARGET}-${PROFILE}-//")"

    out_name="YAOF-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${clean_suffix}"

    cp -f "$img" "${OUTPUT_DIR}/${out_name}"

    log "Saved: ${out_name}"

done < <(find "$IB_BIN_DIR" -type f -name "$MATCH_PATTERN" -print0)

if [ "$FOUND_IMAGE" -eq 0 ]; then
    die "No firmware image found matching: ${MATCH_PATTERN}"
fi

log "Build completed successfully for ${PROFILE}."
