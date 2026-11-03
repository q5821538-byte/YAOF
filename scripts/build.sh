
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
SUBTARGET="${2:-}"
PROFILE="${3:-}"
PACKAGES_PROFILE="${4:-}"
VERSION="${5:-}"

# ============================================================
# OpenClash configuration
# ============================================================

OPENCLASH_TAG="${OPENCLASH_TAG:-v0.48.002}"
OPENCLASH_VERSION="${OPENCLASH_TAG#v}"

OPENCLASH_APK="luci-app-openclash-${OPENCLASH_VERSION}.apk"

OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/${OPENCLASH_TAG}/${OPENCLASH_APK}"

# OpenClash official APK runtime dependencies
OPENCLASH_DEPENDENCIES="
bash
iptables
curl
ca-bundle
ipset
ip-full
iptables-mod-tproxy
iptables-mod-extra
ruby
ruby-yaml
kmod-tun
kmod-inet-diag
unzip
luci-compat
luci
luci-base
dnsmasq-full
"

if [ -z "$TARGET" ] || [ -z "$SUBTARGET" ] || [ -z "$PROFILE" ] || [ -z "$PACKAGES_PROFILE" ]; then
    echo "Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]" >&2
    exit 1
fi

log() {
    printf '[%s] %s\n' "$(date +'%T')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +'%T')" "$*" >&2
    exit 1
}

resolve_version() {
    local req="${1:-}"
    local default_major="25.12"

    if [ -z "$req" ] || [ "$req" = "latest" ]; then
        req="$default_major"
    fi

    local versions

    versions=$(curl -fsSL --retry 3 https://downloads.openwrt.org/releases/ 2>/dev/null | \
        grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?/"' | \
        sed 's/href="//;s/\///;s/"//' | sort -V || true)

    if [ -z "$versions" ]; then
        versions=$(git ls-remote --tags --refs https://github.com/openwrt/openwrt.git 2>/dev/null | \
            awk -F'/' '{print $NF}' | sed 's/^v//' || true)
    fi

    if echo "$versions" | grep -qx "$req"; then
        echo "$req"
        return
    fi

    local matched
    local escaped_req="${req//./\\.}"

    matched=$(echo "$versions" | grep -E "^${escaped_req}\.[0-9]+" | \
        grep -v 'rc' | sort -V | tail -n 1 || true)

    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    matched=$(echo "$versions" | grep -E "^${escaped_req}" | \
        grep -v 'rc' | sort -V | tail -n 1 || true)

    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    echo "${req:-25.12.6}"
}

VERSION=$(resolve_version "$VERSION")
log "Using OpenWrt release: ${VERSION}"

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
# Download ImageBuilder
# ============================================================

if [ ! -d "$IB_DIR" ]; then

    IB_ARCHIVE="${WORK_DIR}/${IB_NAME}.tar.zst"

    IB_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.zst"

    log "Downloading ImageBuilder: ${IB_URL}"

    curl -fsSL --retry 3 --retry-delay 2 "$IB_URL" -o "$IB_ARCHIVE" \
        || die "Failed to download ImageBuilder archive"

    tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR"

    rm -f "$IB_ARCHIVE"

fi

# ============================================================
# OpenWrt custom feed signing key
# ============================================================

mkdir -p "${IB_DIR}/keys"

KEY_URL="https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub"

log "Fetching feed signing key: ${KEY_URL}"

curl -fsSL --retry 3 --retry-delay 2 "$KEY_URL" \
    -o "${IB_DIR}/keys/custom-feed.rsa.pub" \
    || die "Failed to download feed signing key"

FEED_URL="https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb"

if ! grep -qxF "$FEED_URL" "${IB_DIR}/repositories"; then
    sed -i "1i ${FEED_URL}" "${IB_DIR}/repositories"
fi

# ============================================================
# Prepare local APK repository
# ============================================================

mkdir -p "${IB_DIR}/packages"

# ============================================================
# Download OpenClash APK
# ============================================================

OPENCLASH_FILE="${IB_DIR}/packages/${OPENCLASH_APK}"

log "OpenClash version: ${OPENCLASH_TAG}"
log "Downloading OpenClash APK: ${OPENCLASH_URL}"

if [ ! -s "$OPENCLASH_FILE" ]; then

    curl -fL --retry 3 --retry-delay 2 \
        "$OPENCLASH_URL" \
        -o "${OPENCLASH_FILE}.tmp" \
        || die "Failed to download OpenClash APK"

    [ -s "${OPENCLASH_FILE}.tmp" ] \
        || die "OpenClash APK is empty"

    mv "${OPENCLASH_FILE}.tmp" "$OPENCLASH_FILE"

fi

[ -s "$OPENCLASH_FILE" ] \
    || die "OpenClash APK not found"

log "OpenClash APK downloaded successfully"

# ============================================================
# Generate local APK package index
# ============================================================

log "Generating local APK package index..."

make -C "$IB_DIR" package_index \
    || die "Failed to generate local APK package index"

[ -s "${IB_DIR}/packages/packages.adb" ] \
    || die "Local APK package index was not generated"

log "OpenClash local APK index ready"

# ============================================================
# Prepare overlay
# ============================================================

OVERLAY_DIR="${WORK_DIR}/overlay"

rm -rf "$OVERLAY_DIR"

mkdir -p "$OVERLAY_DIR"

if [ -d "${ROOT_DIR}/files" ]; then
    cp -af "${ROOT_DIR}/files/." "$OVERLAY_DIR/"
fi

# ============================================================
# YAOF utility
# ============================================================

mkdir -p "${OVERLAY_DIR}/usr/bin"

FUCK_URL="https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh"

log "Fetching fuck utility: ${FUCK_URL}"

curl -fsSL --retry 3 --retry-delay 2 "$FUCK_URL" \
    -o "${OVERLAY_DIR}/usr/bin/fuck" \
    || die "Failed to download clean-overlay.sh"

chmod +x "${OVERLAY_DIR}/usr/bin/fuck"

# ============================================================
# APK signing key
# ============================================================

mkdir -p "${OVERLAY_DIR}/etc/apk/keys"

cp -af "${IB_DIR}/keys/custom-feed.rsa.pub" \
    "${OVERLAY_DIR}/etc/apk/keys/"

# ============================================================
# Persistent APK repositories
# ============================================================

mkdir -p "${OVERLAY_DIR}/etc/apk/repositories.d"

echo "https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb" \
    > "${OVERLAY_DIR}/etc/apk/repositories.d/customfeeds.list"

if [ "$TARGET" = "rockchip" ]; then

    mkdir -p "${OVERLAY_DIR}/etc/apk"

    echo "aarch64_generic" >> "${OVERLAY_DIR}/etc/apk/arch"

fi

# ============================================================
# Load package profiles
# ============================================================

load_packages() {

    local file="$1"

    [ -f "$file" ] || die "Package profile not found: $file"

    grep -v '^[[:space:]]*#' "$file" | \
        grep -v '^[[:space:]]*$' | \
        tr '\n' ' '

}

PACKAGES="$(load_packages "${ROOT_DIR}/profiles/packages.common")"

PACKAGES="${PACKAGES} $(load_packages "${ROOT_DIR}/profiles/${PACKAGES_PROFILE}")"

# ============================================================
# Add OpenClash and dependencies
# ============================================================

log "Adding OpenClash and runtime dependencies..."

OPENCLASH_PACKAGES="luci-app-openclash"

for pkg in $OPENCLASH_DEPENDENCIES; do
    OPENCLASH_PACKAGES="${OPENCLASH_PACKAGES} ${pkg}"
done

PACKAGES="${PACKAGES} ${OPENCLASH_PACKAGES}"

log "OpenClash packages: ${OPENCLASH_PACKAGES}"

# ============================================================
# Build configuration
# ============================================================

BUILD_LOG="${WORK_DIR}/build.log"

SKIPPED_PACKAGES=""

MAX_SKIP_ROUNDS=5

build_firmware() {

    local packages="$1"

    make -C "$IB_DIR" image \
        PROFILE="$PROFILE" \
        PACKAGES="$packages" \
        FILES="$OVERLAY_DIR" \
        ROOTFS_PARTSIZE="1024" 2>&1 | tee "$BUILD_LOG"

}

# ============================================================
# Detect unavailable packages
# ============================================================

missing_packages_from_log() {

    local log_file="$1"

    sed -nE 's/^[[:space:]]*([^ ]+) \(no such package\):[[:space:]]*$/\1/p' "$log_file"

    sed -nE 's/.*opkg_install_cmd: Cannot install package ([^ ]+)\.$/\1/p' "$log_file"

}

# ============================================================
# Firmware build
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

            # Never silently skip OpenClash or its dependencies
            if [ "$pkg" = "luci-app-openclash" ] || \
               printf '%s\n' "$OPENCLASH_DEPENDENCIES" | \
               grep -qxF -- "$pkg"; then

                die "Required OpenClash package unavailable: ${pkg}. Check APK repositories and dependencies. See ${BUILD_LOG}"

            fi

            skipped="${skipped}${skipped:+ }${pkg}"

        else

            kept="${kept}${kept:+ }${pkg}"

        fi

    done

    if [ -z "$skipped" ]; then

        die "Firmware build failed (no unavailable package detected). See ${BUILD_LOG}"

    fi

    skip_round=$((skip_round + 1))

    if [ "$skip_round" -gt "$MAX_SKIP_ROUNDS" ]; then

        die "Too many unavailable packages; last skipped: ${skipped}. See ${BUILD_LOG}"

    fi

    log "WARNING: Package(s) not available in repositories, skipping: ${skipped}"

    SKIPPED_PACKAGES="${SKIPPED_PACKAGES}${SKIPPED_PACKAGES:+ }${skipped}"

    PACKAGES="$kept"

done

# ============================================================
# Build result
# ============================================================

if [ -n "$SKIPPED_PACKAGES" ]; then

    log "WARNING: Firmware built without unavailable package(s): ${SKIPPED_PACKAGES}"

fi

IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"

[ -d "$IB_BIN_DIR" ] \
    || die "Output directory not found: $IB_BIN_DIR"

DATE_STR=$(date +%Y-%m-%d)

PLATFORM_LABEL=$(echo "$PROFILE" | \
    sed 's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/')

MATCH_PATTERN="*sysupgrade.img.gz"

if [ "$TARGET" = "x86" ]; then
    MATCH_PATTERN="*combined-efi.img.gz"
fi

find "$IB_BIN_DIR" -type f -name "$MATCH_PATTERN" | while read -r img; do

    fname=$(basename "$img")

    clean_suffix=$(echo "$fname" | \
        sed -E "s/^openwrt-.*-${TARGET}-${SUBTARGET}-${PROFILE}-//")

    out_name="YAOF-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${clean_suffix}"

    cp -f "$img" "${OUTPUT_DIR}/${out_name}"

    log "Saved: ${out_name}"

done

log "Build completed successfully for ${PROFILE}."
