
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

# ============================================================
# Resolve OpenWrt version
# ============================================================

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

# ============================================================
# Architecture
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

# PassWall uses the OpenWrt major.minor release directory.
PASSWALL_RELEASE="${VERSION%.*}"

log "Architecture: ${ARCH}"
log "PassWall release: ${PASSWALL_RELEASE}"

# ============================================================
# Directories
# ============================================================

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

    curl -fsSL --retry 3 --retry-delay 2 "$IB_URL" \
        -o "$IB_ARCHIVE" || die "Failed to download ImageBuilder archive"

    tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR"

    rm -f "$IB_ARCHIVE"
fi

[ -d "$IB_DIR" ] || die "ImageBuilder directory not found"

mkdir -p "${IB_DIR}/keys"
mkdir -p "${IB_DIR}/packages"

[ -f "${IB_DIR}/repositories" ] || die "ImageBuilder repositories file not found"

# ============================================================
# YAOF repository
# ============================================================

KEY_URL="https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub"

log "Fetching YAOF feed signing key: ${KEY_URL}"

curl -fsSL --retry 3 --retry-delay 2 "$KEY_URL" \
    -o "${IB_DIR}/keys/custom-feed.rsa.pub" \
    || die "Failed to download YAOF signing key"

FEED_URL="https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb"

log "Checking YAOF repository"

curl -fsSL --retry 3 "$FEED_URL" -o /dev/null \
    || die "YAOF repository unavailable: ${FEED_URL}"

if ! grep -qxF "$FEED_URL" "${IB_DIR}/repositories"; then
    sed -i "1i ${FEED_URL}" "${IB_DIR}/repositories"
fi

# ============================================================
# PassWall repositories
# ============================================================

PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PASSWALL_RELEASE}/${ARCH}"

PASSWALL_LUCI="${PASSWALL_BASE}/passwall_luci/packages.adb"
PASSWALL_PACKAGES="${PASSWALL_BASE}/passwall_packages/packages.adb"
PASSWALL2="${PASSWALL_BASE}/passwall2/packages.adb"

PASSWALL_KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub"

log "Fetching PassWall signing key"

curl -fsSL --retry 3 --retry-delay 2 "$PASSWALL_KEY_URL" \
    -o "${IB_DIR}/keys/openwrt-passwall-build.pem" \
    || die "Failed to download PassWall signing key"

log "Checking PassWall repositories"

for repo in "$PASSWALL_LUCI" "$PASSWALL_PACKAGES" "$PASSWALL2"; do
    log "Checking: ${repo}"

    curl -fsSL --retry 3 "$repo" -o /dev/null \
        || die "PassWall repository unavailable: ${repo}"
done

# Add PassWall repositories to ImageBuilder.
for repo in "$PASSWALL_LUCI" "$PASSWALL_PACKAGES" "$PASSWALL2"; do
    if ! grep -qxF "$repo" "${IB_DIR}/repositories"; then
        printf '%s\n' "$repo" >> "${IB_DIR}/repositories"
    fi
done

# ============================================================
# OpenClash official APK
# ============================================================

OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/${OPENCLASH_TAG}/luci-app-openclash-${OPENCLASH_VERSION}.apk"

OPENCLASH_APK="${IB_DIR}/packages/luci-app-openclash-${OPENCLASH_VERSION}.apk"

log "Downloading OpenClash ${OPENCLASH_TAG}"

curl -fL --retry 3 --retry-delay 2 "$OPENCLASH_URL" \
    -o "$OPENCLASH_APK" \
    || die "Failed to download OpenClash APK"

[ -s "$OPENCLASH_APK" ] || die "OpenClash APK is empty"

log "OpenClash APK downloaded: ${OPENCLASH_APK}"

# OpenWrt 25.12 ImageBuilder automatically indexes
# local APK packages in the packages/ directory.

# ============================================================
# Overlay
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
# APK signing keys in firmware
# ============================================================

mkdir -p "${OVERLAY_DIR}/etc/apk/keys"

cp -af "${IB_DIR}/keys/custom-feed.rsa.pub" \
    "${OVERLAY_DIR}/etc/apk/keys/"

cp -af "${IB_DIR}/keys/openwrt-passwall-build.pem" \
    "${OVERLAY_DIR}/etc/apk/keys/"

# ============================================================
# Runtime custom repositories
# ============================================================

mkdir -p "${OVERLAY_DIR}/etc/apk/repositories.d"

cat > "${OVERLAY_DIR}/etc/apk/repositories.d/customfeeds.list" <<EOF
${FEED_URL}
${PASSWALL_LUCI}
${PASSWALL_PACKAGES}
${PASSWALL2}
EOF

# ============================================================
# Rockchip APK architecture
# ============================================================

if [ "$TARGET" = "rockchip" ]; then
    mkdir -p "${OVERLAY_DIR}/etc/apk"

    ARCH_FILE="${OVERLAY_DIR}/etc/apk/arch"
    touch "$ARCH_FILE"

    if ! grep -qxF "aarch64_generic" "$ARCH_FILE"; then
        echo "aarch64_generic" >> "$ARCH_FILE"
    fi
fi

# ============================================================
# Load package profiles
# ============================================================

load_packages() {
    local file="$1"

    [ -f "$file" ] || die "Package profile not found: $file"

    grep -v '^[[:space:]]*#' "$file" |
        grep -v '^[[:space:]]*$' |
        tr '\n' ' '
}

PACKAGES="$(load_packages "${ROOT_DIR}/profiles/packages.common")"
PACKAGES="${PACKAGES} $(load_packages "${ROOT_DIR}/profiles/${PACKAGES_PROFILE}")"

# ============================================================
# Add OpenClash and PassWall applications
# ============================================================

# OpenClash is supplied by the local APK downloaded above.
# PassWall and its Chinese translation are supplied by PassWall feeds.

PACKAGES="${PACKAGES} luci-app-openclash"
PACKAGES="${PACKAGES} luci-app-passwall"
PACKAGES="${PACKAGES} luci-i18n-passwall-zh-cn"

# Remove duplicate package names, preserving order.
PACKAGES="$(printf '%s\n' $PACKAGES | awk 'NF && !seen[$0]++' | tr '\n' ' ')"

# These three packages must never be silently skipped.
REQUIRED_PACKAGES="
luci-app-openclash
luci-app-passwall
luci-i18n-passwall-zh-cn
"

BUILD_LOG="${WORK_DIR}/build.log"
SKIPPED_PACKAGES=""
MAX_SKIP_ROUNDS=5

# ============================================================
# Build firmware
# ============================================================

build_firmware() {
    local packages="$1"

    make -C "$IB_DIR" image \
        PROFILE="$PROFILE" \
        PACKAGES="$packages" \
        FILES="$OVERLAY_DIR" \
        ROOTFS_PARTSIZE="1024" 2>&1 | tee "$BUILD_LOG"
}

# ============================================================
# Detect missing packages
# ============================================================

missing_packages_from_log() {
    local log_file="$1"

    # APK (OpenWrt 25.x)
    sed -nE 's/^[[:space:]]*([^ ]+) \(no such package\):[[:space:]]*$/\1/p' "$log_file"

    # OPKG (OpenWrt 24.x and older)
    sed -nE 's/.*opkg_install_cmd: Cannot install package ([^ ]+)\.$/\1/p' "$log_file"
}

# ============================================================
# Build loop
# ============================================================

log "Assembling firmware for ${PROFILE} (${VERSION})..."
log "OpenClash: ${OPENCLASH_TAG}"
log "PassWall: enabled"
log "PassWall Chinese translation: enabled"

skip_round=0

while :; do

    if build_firmware "$PACKAGES"; then
        break
    fi

    missing="$(missing_packages_from_log "$BUILD_LOG" | sort -u)"

    if [ -z "$missing" ]; then
        die "Firmware build failed (no unavailable package detected). See ${BUILD_LOG}"
    fi

    # Never skip OpenClash, PassWall or its Chinese translation.
    for required in $REQUIRED_PACKAGES; do
        if printf '%s\n' "$missing" | grep -qxF -- "$required"; then
            die "Required package unavailable: ${required}. Build stopped."
        fi
    done

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

    skip_round=$((skip_round + 1))

    if [ "$skip_round" -gt "$MAX_SKIP_ROUNDS" ]; then
        die "Too many unavailable packages; last skipped: ${skipped}. See ${BUILD_LOG}"
    fi

    log "WARNING: Package(s) not available in repositories, skipping: ${skipped}"

    SKIPPED_PACKAGES="${SKIPPED_PACKAGES}${SKIPPED_PACKAGES:+ }${skipped}"

    PACKAGES="$kept"
done

if [ -n "$SKIPPED_PACKAGES" ]; then
    log "WARNING: Firmware built without unavailable package(s): ${SKIPPED_PACKAGES}"
fi

# ============================================================
# Locate firmware output
# ============================================================

IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"

[ -d "$IB_BIN_DIR" ] || die "Output directory not found: $IB_BIN_DIR"

DATE_STR=$(date +%Y-%m-%d)

PLATFORM_LABEL=$(echo "$PROFILE" | sed \
    's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/')

MATCH_PATTERN="*sysupgrade.img.gz"

if [ "$TARGET" = "x86" ]; then
    MATCH_PATTERN="*combined-efi.img.gz"
fi

IMAGE_COUNT=0

while IFS= read -r -d '' img; do
    fname=$(basename "$img")

    clean_suffix=$(echo "$fname" | sed \
        -E "s/^openwrt-.*-${TARGET}-${SUBTARGET}-${PROFILE}-//")

    out_name="YAOF-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${clean_suffix}"

    cp -f "$img" "${OUTPUT_DIR}/${out_name}"

    log "Saved: ${out_name}"

    IMAGE_COUNT=$((IMAGE_COUNT + 1))

done < <(find "$IB_BIN_DIR" -type f -name "$MATCH_PATTERN" -print0)

[ "$IMAGE_COUNT" -gt 0 ] || die "No firmware image found: ${MATCH_PATTERN}"

# ============================================================
# Summary
# ============================================================

log "Build completed successfully for ${PROFILE}."

log "OpenClash: ${OPENCLASH_TAG}"
log "PassWall: installed"
log "PassWall Chinese translation: installed"

log "Firmware images generated: ${IMAGE_COUNT}"

if [ -n "$SKIPPED_PACKAGES" ]; then
    log "WARNING: Other unavailable packages were skipped: ${SKIPPED_PACKAGES}"
fi

ls -lh "${OUTPUT_DIR}/"
