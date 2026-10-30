#!/usr/bin/env bash
set -Eeuo pipefail

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

# ============================================================
# Arguments
# ============================================================

if [[ -z "$TARGET" || -z "$SUBTARGET" ||
      -z "$PROFILE" || -z "$PACKAGES_PROFILE" ]]; then
    echo "Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]" >&2
    exit 1
fi

# ============================================================
# Logging
# ============================================================

log() {
    printf '[%s] %s\n' "$(date +'%T')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +'%T')" "$*" >&2
    exit 1
}

# ============================================================
# Resolve OpenWrt version
# IMPORTANT:
# Only the version number is written to stdout.
# All log messages are written to stderr.
# ============================================================

resolve_version() {
    local req="${1:-}"
    local default_major="25.12"
    local versions
    local matched
    local escaped_req

    if [[ -z "$req" || "$req" == "latest" ]]; then
        req="$default_major"
    fi

    log "Checking available OpenWrt releases..." >&2

    versions="$(
        curl -fsSL --retry 3 --retry-delay 2 \
            https://downloads.openwrt.org/releases/ 2>/dev/null |
        grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' |
        sed 's/href="//;s/\///;s/"//' |
        sort -V || true
    )"

    [[ -n "$versions" ]] ||
        die "Unable to retrieve OpenWrt release list."

    if printf '%s\n' "$versions" | grep -qxF "$req"; then
        printf '%s\n' "$req"
        return 0
    fi

    escaped_req="${req//./\\.}"

    matched="$(
        printf '%s\n' "$versions" |
        grep -E "^${escaped_req}\.[0-9]+$" |
        sort -V |
        tail -n 1 || true
    )"

    if [[ -n "$matched" ]]; then
        printf '%s\n' "$matched"
        return 0
    fi

    die "OpenWrt release not found: ${req}"
}

VERSION="$(resolve_version "$VERSION")"

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

BUILD_LOG="${WORK_DIR}/build.log"

# ============================================================
# Download ImageBuilder
# ============================================================

if [[ ! -d "$IB_DIR" ]]; then

    IB_ARCHIVE="${WORK_DIR}/${IB_NAME}.tar.zst"

    IB_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.zst"

    log "Downloading ImageBuilder:"
    log "$IB_URL"

    curl -fL --retry 3 --retry-delay 2 \
        "$IB_URL" -o "$IB_ARCHIVE" ||
        die "Failed to download ImageBuilder."

    log "Extracting ImageBuilder..."

    tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR" ||
        die "Failed to extract ImageBuilder."

    rm -f "$IB_ARCHIVE"
fi

[[ -d "$IB_DIR" ]] ||
    die "ImageBuilder directory not found."

[[ -f "${IB_DIR}/repositories" ]] ||
    die "ImageBuilder repositories file not found."

mkdir -p "${IB_DIR}/keys"
mkdir -p "${IB_DIR}/packages"

# ============================================================
# Download and validate repository files
# ============================================================

download_nonempty() {
    local url="$1"
    local output="$2"
    local description="$3"

    log "Downloading ${description}"

    curl -fL --retry 3 --retry-delay 2 \
        "$url" -o "$output" ||
        die "Download failed: ${description}"

    [[ -s "$output" ]] ||
        die "Downloaded file is empty: ${description}"
}

# ============================================================
# YAOF repository
# ============================================================

KEY_URL="https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub"

FEED_URL="https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb"

download_nonempty \
    "$KEY_URL" \
    "${IB_DIR}/keys/custom-feed.rsa.pub" \
    "YAOF signing key"

YAOF_INDEX="${WORK_DIR}/yaof-packages.adb"

download_nonempty \
    "$FEED_URL" \
    "$YAOF_INDEX" \
    "YAOF package index"

rm -f "$YAOF_INDEX"

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

download_nonempty \
    "$PASSWALL_KEY_URL" \
    "${IB_DIR}/keys/openwrt-passwall-build.pem" \
    "PassWall APK signing key"

check_passwall_repo() {
    local repo="$1"
    local name="$2"
    local temp_file="${WORK_DIR}/check-${name}.adb"

    download_nonempty \
        "$repo" \
        "$temp_file" \
        "$name package index"

    rm -f "$temp_file"
}

log "Checking PassWall repositories..."

check_passwall_repo "$PASSWALL_LUCI" "passwall-luci"

check_passwall_repo "$PASSWALL_PACKAGES" "passwall-packages"

check_passwall_repo "$PASSWALL2" "passwall2"

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

download_nonempty \
    "$OPENCLASH_URL" \
    "$OPENCLASH_APK" \
    "OpenClash ${OPENCLASH_TAG} APK"

log "OpenClash APK ready: ${OPENCLASH_APK}"

# ImageBuilder automatically indexes local APK packages.

# ============================================================
# Overlay
# ============================================================

OVERLAY_DIR="${WORK_DIR}/overlay"

rm -rf "$OVERLAY_DIR"

mkdir -p "$OVERLAY_DIR"

if [[ -d "${ROOT_DIR}/files" ]]; then
    cp -af "${ROOT_DIR}/files/." "$OVERLAY_DIR/"
fi

# ============================================================
# YAOF utility
# ============================================================

mkdir -p "${OVERLAY_DIR}/usr/bin"

FUCK_URL="https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh"

download_nonempty \
    "$FUCK_URL" \
    "${OVERLAY_DIR}/usr/bin/fuck" \
    "YAOF clean-overlay utility"

chmod +x "${OVERLAY_DIR}/usr/bin/fuck"

# ============================================================
# APK signing keys in firmware
# ============================================================

mkdir -p "${OVERLAY_DIR}/etc/apk/keys"

cp -af \
    "${IB_DIR}/keys/custom-feed.rsa.pub" \
    "${OVERLAY_DIR}/etc/apk/keys/"

cp -af \
    "${IB_DIR}/keys/openwrt-passwall-build.pem" \
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

if [[ "$TARGET" == "rockchip" ]]; then

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

    [[ -f "$file" ]] ||
        die "Package profile not found: ${file}"

    awk '
    {
        sub(/\r$/, "")
        sub(/[[:space:]]+#.*/, "")

        if ($0 ~ /^[[:space:]]*#/) next
        if ($0 ~ /^[[:space:]]*$/) next

        gsub(/^[ \t]+|[ \t]+$/, "")

        if ($0 != "") print
    }
    ' "$file" | tr '\n' ' '
}

PACKAGES_COMMON="${ROOT_DIR}/profiles/packages.common"

PACKAGES_CUSTOM="${ROOT_DIR}/profiles/${PACKAGES_PROFILE}"

PACKAGES="$(load_packages "$PACKAGES_COMMON")"

PACKAGES="${PACKAGES} $(load_packages "$PACKAGES_CUSTOM")"

# ============================================================
# Add required proxy applications
# ============================================================

PACKAGES="${PACKAGES} luci-app-openclash"

PACKAGES="${PACKAGES} luci-app-passwall"

PACKAGES="${PACKAGES} luci-i18n-passwall-zh-cn"

# ============================================================
# Remove duplicate package entries
# ============================================================

deduplicate_packages() {
    local input="$1"
    local token
    local result=""
    local -A seen=()

    for token in $input; do

        if [[ -z "${seen[$token]+x}" ]]; then

            seen["$token"]=1

            result="${result}${result:+ }${token}"

        fi

    done

    printf '%s' "$result"
}

PACKAGES="$(deduplicate_packages "$PACKAGES")"

# ============================================================
# Required package validation
# ============================================================

REQUIRED_PACKAGES=(
    "luci-app-openclash"
    "luci-app-passwall"
    "luci-i18n-passwall-zh-cn"
)

for required in "${REQUIRED_PACKAGES[@]}"; do

    if [[ " $PACKAGES " == *" -${required} "* ]]; then
        die "Required package is explicitly excluded: ${required}"
    fi

    if [[ " $PACKAGES " != *" ${required} "* ]]; then
        die "Required package missing from package list: ${required}"
    fi

done

# ============================================================
# Print package list
# ============================================================

log "Package profile: ${PACKAGES_PROFILE}"

log "Packages to install:"

for pkg in $PACKAGES; do
    log "  ${pkg}"
done

# ============================================================
# Build firmware
# ============================================================

build_firmware() {

    log "Starting ImageBuilder..."

    make -C "$IB_DIR" image \
        PROFILE="$PROFILE" \
        PACKAGES="$PACKAGES" \
        FILES="$OVERLAY_DIR" \
        ROOTFS_PARTSIZE="1024" \
        2>&1 | tee "$BUILD_LOG"

}

# ============================================================
# Build
# ============================================================

log "============================================================"

log "Building firmware"

log "OpenWrt: ${VERSION}"

log "Target: ${TARGET}/${SUBTARGET}"

log "Profile: ${PROFILE}"

log "Architecture: ${ARCH}"

log "OpenClash: ${OPENCLASH_TAG}"

log "PassWall: enabled"

log "PassWall Chinese translation: enabled"

log "============================================================"

if ! build_firmware; then
    die "Firmware build failed. Check log: ${BUILD_LOG}"
fi

# ============================================================
# Check plugin post-install warnings
# ============================================================

if grep -E \
    '(/lib/functions\.sh: No such file|/lib/functions/network\.sh: No such file|/usr/share/openclash/.*No such file|/usr/share/passwall/.*No such file)' \
    "$BUILD_LOG" >/dev/null 2>&1; then

    log "WARNING: Plugin post-install script warnings were detected."

    log "WARNING: Check OpenClash and PassWall after first boot."

    log "WARNING: See ${BUILD_LOG}"

fi

# ============================================================
# Locate firmware output
# ============================================================

IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"

[[ -d "$IB_BIN_DIR" ]] ||
    die "Output directory not found: ${IB_BIN_DIR}"

DATE_STR="$(date +%Y-%m-%d)"

PLATFORM_LABEL="$(echo "$PROFILE" | sed \
    's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/')"

MATCH_PATTERN="*sysupgrade.img.gz"

if [[ "$TARGET" == "x86" ]]; then
    MATCH_PATTERN="*combined-efi.img.gz"
fi

# ============================================================
# Copy firmware images
# ============================================================

IMAGE_COUNT=0

while IFS= read -r -d '' img; do

    fname="$(basename "$img")"

    clean_suffix="$(echo "$fname" | sed \
        -E "s/^openwrt-.*-${TARGET}-${SUBTARGET}-${PROFILE}-//")"

    out_name="YAOF-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${clean_suffix}"

    cp -f "$img" "${OUTPUT_DIR}/${out_name}"

    log "Saved: ${out_name}"

    IMAGE_COUNT=$((IMAGE_COUNT + 1))

done < <(
    find "$IB_BIN_DIR" \
        -type f \
        -name "$MATCH_PATTERN" \
        -print0
)

[[ "$IMAGE_COUNT" -gt 0 ]] ||
    die "No firmware image found: ${MATCH_PATTERN}"

# ============================================================
# Final summary
# ============================================================

log "============================================================"

log "Build completed successfully."

log "OpenWrt: ${VERSION}"

log "Target: ${TARGET}/${SUBTARGET}"

log "Profile: ${PROFILE}"

log "OpenClash requested: ${OPENCLASH_TAG}"

log "PassWall requested: yes"

log "PassWall Chinese translation requested: yes"

log "Firmware images generated: ${IMAGE_COUNT}"

log "Output directory: ${OUTPUT_DIR}"

log "Build log: ${BUILD_LOG}"

log "============================================================"

ls -lh "${OUTPUT_DIR}/"
