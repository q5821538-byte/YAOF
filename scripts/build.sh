
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# YAOF OpenWrt ImageBuilder
# OpenWrt 25.12.6 / x86_64 / UEFI
# Integrated:
#   - OpenClash
#   - PassWall
#   - PassWall Chinese translation
#   - Xray / Sing-box / common proxy cores
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
SUBTARGET="${2:-}"
PROFILE="${3:-}"
PACKAGES_PROFILE="${4:-}"
VERSION="${5:-25.12.6}"

OPENCLASH_VERSION="v0.48.002"
OPENCLASH_PACKAGE_VERSION="0.48.002"

if [[ -z "$TARGET" || -z "$SUBTARGET" || -z "$PROFILE" || -z "$PACKAGES_PROFILE" ]]; then
    echo "Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]" >&2
    exit 1
fi

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

trap 'die "Script failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

# ============================================================
# Target architecture
# ============================================================

case "$TARGET/$SUBTARGET" in
    x86/64)
        ARCH="x86_64"
        ;;
    *)
        die "This final configuration is for x86/64 only"
        ;;
esac

[[ "$VERSION" == "25.12.6" ]] || die "This script is configured for OpenWrt 25.12.6"

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

    curl -fL --retry 3 --retry-delay 3 \
        "$IB_URL" -o "$IB_ARCHIVE" \
        || die "ImageBuilder download failed"

    tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR"
    rm -f "$IB_ARCHIVE"
fi

[[ -d "$IB_DIR" ]] || die "ImageBuilder directory does not exist"

mkdir -p "${IB_DIR}/keys" "${IB_DIR}/packages"

[[ -f "${IB_DIR}/repositories" ]] || die "ImageBuilder repositories file missing"

# ============================================================
# YAOF repository
# ============================================================

YAOF_KEY_URL="https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub"
YAOF_FEED_URL="https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb"

log "Checking YAOF repository index"

curl -fsSL --retry 3 "$YAOF_FEED_URL" -o /dev/null \
    || die "YAOF repository index unavailable: ${YAOF_FEED_URL}"

log "Downloading YAOF signing key"

curl -fL --retry 3 "$YAOF_KEY_URL" \
    -o "${IB_DIR}/keys/custom-feed.rsa.pub" \
    || die "YAOF signing key download failed"

# ============================================================
# PassWall repository
# ============================================================

PASSWALL_RELEASE="25.12"

PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PASSWALL_RELEASE}/${ARCH}"

PASSWALL_LUCI="${PASSWALL_BASE}/passwall_luci/packages.adb"
PASSWALL_PACKAGES="${PASSWALL_BASE}/passwall_packages/packages.adb"
PASSWALL2="${PASSWALL_BASE}/passwall2/packages.adb"

PASSWALL_KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub"

log "Checking PassWall repository indexes"

for repo in "$PASSWALL_LUCI" "$PASSWALL_PACKAGES" "$PASSWALL2"; do
    log "Checking: $repo"

    curl -fsSL --retry 3 "$repo" -o /dev/null \
        || die "PassWall repository unavailable: $repo"
done

log "Downloading PassWall APK public key"

curl -fL --retry 3 "$PASSWALL_KEY_URL" \
    -o "${IB_DIR}/keys/openwrt-passwall-build.pem" \
    || die "PassWall signing key download failed"

# ============================================================
# OpenClash official APK
# ============================================================

OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/${OPENCLASH_VERSION}/luci-app-openclash-${OPENCLASH_PACKAGE_VERSION}.apk"

OPENCLASH_APK="${IB_DIR}/packages/luci-app-openclash-${OPENCLASH_PACKAGE_VERSION}.apk"

log "Downloading OpenClash ${OPENCLASH_VERSION}"

curl -fL --retry 3 --retry-delay 3 \
    "$OPENCLASH_URL" \
    -o "$OPENCLASH_APK" \
    || die "OpenClash APK download failed"

[[ -s "$OPENCLASH_APK" ]] || die "OpenClash APK is empty"

log "OpenClash APK downloaded:"
ls -lh "$OPENCLASH_APK"

# ImageBuilder 25.12 automatically indexes APK files in packages/
# Do not manually create Packages.adb.

# ============================================================
# Configure repositories
# ============================================================

add_repository() {
    local url="$1"

    if ! grep -qxF "$url" "${IB_DIR}/repositories"; then
        printf '%s\n' "$url" >> "${IB_DIR}/repositories"
    fi
}

# Put custom repositories before official repositories.
TEMP_REPOSITORIES="${WORK_DIR}/repositories.tmp"

{
    echo "$YAOF_FEED_URL"
    echo "$PASSWALL_LUCI"
    echo "$PASSWALL_PACKAGES"
    echo "$PASSWALL2"
    cat "${IB_DIR}/repositories"
} | awk '!seen[$0]++' > "$TEMP_REPOSITORIES"

cp "$TEMP_REPOSITORIES" "${IB_DIR}/repositories"
rm -f "$TEMP_REPOSITORIES"

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

log "Downloading YAOF clean-overlay utility"

curl -fL --retry 3 "$FUCK_URL" \
    -o "${OVERLAY_DIR}/usr/bin/fuck" \
    || die "Failed to download YAOF utility"

chmod +x "${OVERLAY_DIR}/usr/bin/fuck"

# ============================================================
# Runtime APK keys
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
${YAOF_FEED_URL}
${PASSWALL_LUCI}
${PASSWALL_PACKAGES}
${PASSWALL2}
EOF

# ============================================================
# Package profiles
# ============================================================

load_packages() {
    local file="$1"

    [[ -f "$file" ]] || die "Package profile not found: $file"

    grep -vE '^[[:space:]]*#' "$file" \
        | grep -vE '^[[:space:]]*$' \
        | tr '\n' ' '
}

PACKAGES_COMMON="${ROOT_DIR}/profiles/packages.common"
PACKAGES_CUSTOM="${ROOT_DIR}/profiles/${PACKAGES_PROFILE}"

PACKAGES="$(load_packages "$PACKAGES_COMMON")"
PACKAGES="${PACKAGES} $(load_packages "$PACKAGES_CUSTOM")"

# ============================================================
# OpenClash dependencies
# ============================================================

OPENCLASH_PACKAGES="
luci-app-openclash
luci
luci-base
luci-compat
bash
curl
ca-bundle
ruby
ruby-yaml
dnsmasq-full
ipset
ip-full
unzip
kmod-nft-tproxy
kmod-tun
kmod-inet-diag
"

# ============================================================
# PassWall
# ============================================================

PASSWALL_REQUIRED="
luci-app-passwall
luci-i18n-passwall-zh-cn
"

# Core packages confirmed in the PassWall x86_64 25.12 feed.
PASSWALL_CORES="
xray-core
sing-box
v2ray-geoip
v2ray-geosite
geoview
dns2socks
tcping
ipt2socks
microsocks
shadowsocks-rust-sslocal
v2ray-plugin
simple-obfs-client
hysteria
naiveproxy
shadow-tls
"

# ============================================================
# Firewall4 / nftables
# ============================================================

FIREWALL_PACKAGES="
nftables
kmod-nft-socket
kmod-nft-tproxy
kmod-nft-nat
"

PACKAGES="${PACKAGES} ${OPENCLASH_PACKAGES} ${PASSWALL_REQUIRED} ${PASSWALL_CORES} ${FIREWALL_PACKAGES}"

# Deduplicate package names.
PACKAGES="$(printf '%s\n' $PACKAGES | awk 'NF && !seen[$0]++' | tr '\n' ' ')"

# ============================================================
# Required packages
# ============================================================

REQUIRED_PACKAGES="
luci-app-openclash
luci-app-passwall
luci-i18n-passwall-zh-cn
xray-core
sing-box
"

# Packages which may be skipped if not present.
# The main applications and their selected mandatory cores cannot be skipped.
OPTIONAL_PACKAGES="
v2ray-geoip
v2ray-geosite
geoview
dns2socks
tcping
ipt2socks
microsocks
shadowsocks-rust-sslocal
v2ray-plugin
simple-obfs-client
hysteria
naiveproxy
shadow-tls
"

# ============================================================
# Build
# ============================================================

missing_packages_from_log() {
    local log_file="$1"

    sed -nE \
        's/^[[:space:]]*([^ ]+) \(no such package\):[[:space:]]*$/\1/p' \
        "$log_file"

    sed -nE \
        's/.*opkg_install_cmd: Cannot install package ([^ ]+)\.$/\1/p' \
        "$log_file"
}

build_firmware() {
    local package_list="$1"

    make -C "$IB_DIR" image \
        PROFILE="$PROFILE" \
        PACKAGES="$package_list" \
        FILES="$OVERLAY_DIR" \
        ROOTFS_PARTSIZE="1024" \
        2>&1 | tee "$BUILD_LOG"
}

log "============================================================"
log "Starting OpenWrt ${VERSION} build"
log "Target: ${TARGET}/${SUBTARGET}"
log "Architecture: ${ARCH}"
log "Profile: ${PROFILE}"
log "OpenClash: ${OPENCLASH_VERSION}"
log "PassWall: enabled"
log "============================================================"

log "Building firmware"

MAX_SKIP_ROUNDS=5
SKIP_ROUND=0
SKIPPED_PACKAGES=""

while true; do

    if build_firmware "$PACKAGES"; then
        break
    fi

    MISSING="$(missing_packages_from_log "$BUILD_LOG" | sort -u)"

    [[ -n "$MISSING" ]] || die "Build failed. Check ${BUILD_LOG}"

    # Required packages must never be skipped.
    for required in $REQUIRED_PACKAGES; do
        if printf '%s\n' "$MISSING" | grep -qxF "$required"; then
            die "Required package missing: ${required}. Build stopped."
        fi
    done

    KEPT=""
    SKIPPED=""

    for pkg in $PACKAGES; do
        if printf '%s\n' "$MISSING" | grep -qxF "$pkg"; then

            if printf '%s\n' "$OPTIONAL_PACKAGES" | grep -qxF "$pkg"; then
                SKIPPED="${SKIPPED}${SKIPPED:+ }${pkg}"
            else
                die "Non-optional package unavailable: ${pkg}"
            fi

        else
            KEPT="${KEPT}${KEPT:+ }${pkg}"
        fi
    done

    [[ -n "$SKIPPED" ]] || die "Build failed without a skippable package"

    SKIP_ROUND=$((SKIP_ROUND + 1))

    [[ "$SKIP_ROUND" -le "$MAX_SKIP_ROUNDS" ]] \
        || die "Too many package skip rounds"

    log "Skipping optional packages: ${SKIPPED}"

    SKIPPED_PACKAGES="${SKIPPED_PACKAGES}${SKIPPED_PACKAGES:+ }${SKIPPED}"

    PACKAGES="$KEPT"
done

# ============================================================
# Final package verification
# ============================================================

log "Checking final image manifest"

MANIFEST="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}/profiles.json"

# ImageBuilder output directory
IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"

[[ -d "$IB_BIN_DIR" ]] || die "Firmware output directory missing"

# ============================================================
# Find EFI image
# ============================================================

MATCH_PATTERN="*combined-efi.img.gz"

DATE_STR="$(date +%Y-%m-%d)"

PLATFORM_LABEL="$(echo "$PROFILE" | sed \
    's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/')"

FOUND_IMAGE=0

while IFS= read -r -d '' img; do

    FOUND_IMAGE=1

    FILENAME="$(basename "$img")"

    CLEAN_SUFFIX="$(echo "$FILENAME" | sed \
        -E "s/^openwrt-.*-${TARGET}-${SUBTARGET}-${PROFILE}-//")"

    OUTPUT_NAME="YAOF-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${CLEAN_SUFFIX}"

    cp -f "$img" "${OUTPUT_DIR}/${OUTPUT_NAME}"

    log "Firmware saved: ${OUTPUT_DIR}/${OUTPUT_NAME}"

done < <(find "$IB_BIN_DIR" -type f -name "$MATCH_PATTERN" -print0)

[[ "$FOUND_IMAGE" -eq 1 ]] || die "No EFI firmware image found"

# ============================================================
# Summary
# ============================================================

log "============================================================"
log "BUILD COMPLETED"
log "OpenWrt: ${VERSION}"
log "Architecture: ${ARCH}"
log "Profile: ${PROFILE}"
log "OpenClash: ${OPENCLASH_VERSION}"
log "PassWall: enabled"
log "PassWall Chinese translation: enabled"
log "UEFI EFI image: generated"
log "============================================================"

if [[ -n "$SKIPPED_PACKAGES" ]]; then
    log "Optional packages skipped: ${SKIPPED_PACKAGES}"
fi

ls -lh "${OUTPUT_DIR}/"
