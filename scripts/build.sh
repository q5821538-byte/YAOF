#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
SUBTARGET="${2:-}"
PROFILE="${3:-}"
PACKAGES_PROFILE="${4:-}"
VERSION="${5:-}"

# OpenClash version
OPENCLASH_TAG="${OPENCLASH_TAG:-v0.48.002}"

log() {
    printf '[%s] %s\n' "$(date +'%T')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +'%T')" "$*" >&2
    exit 1
}

[[ -n "$TARGET" && -n "$SUBTARGET" && -n "$PROFILE" && -n "$PACKAGES_PROFILE" ]] \
    || die "Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]"

for cmd in curl tar python3 sha256sum awk grep sed sort find make; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# ============================================================
# OpenWrt version
# ============================================================

resolve_version() {
    local req="${1:-}"
    local default_major="25.12"
    local versions matched escaped_req

    [[ -n "$req" && "$req" != "latest" ]] || req="$default_major"

    log "Checking available OpenWrt releases..." >&2

    versions="$(
        curl -fsSL --retry 3 --retry-delay 2 \
            https://downloads.openwrt.org/releases/ 2>/dev/null \
        | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
        | sed -E 's/^href="([0-9]+\.[0-9]+\.[0-9]+)\/"$/\1/' \
        | sort -Vu || true
    )"

    [[ -n "$versions" ]] || die "Unable to retrieve OpenWrt release list."

    if printf '%s\n' "$versions" | grep -qxF "$req"; then
        printf '%s\n' "$req"
        return 0
    fi

    escaped_req="${req//./\\.}"

    matched="$(
        printf '%s\n' "$versions" \
        | grep -E "^${escaped_req}\.[0-9]+$" \
        | sort -V \
        | tail -n 1 || true
    )"

    [[ -n "$matched" ]] || die "OpenWrt release not found: ${req}"

    printf '%s\n' "$matched"
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
log "PassWall release feed: ${PASSWALL_RELEASE}"

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

if [[ ! -s "${IB_DIR}/Makefile" || ! -s "${IB_DIR}/repositories" ]]; then

    IB_ARCHIVE="${WORK_DIR}/${IB_NAME}.tar.zst"

    IB_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.zst"

    rm -rf "$IB_DIR"

    log "Downloading ImageBuilder: ${IB_URL}"

    curl -fL --retry 3 --retry-delay 2 "$IB_URL" -o "$IB_ARCHIVE" \
        || die "Failed to download ImageBuilder."

    tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR" \
        || die "Failed to extract ImageBuilder."

    rm -f "$IB_ARCHIVE"
fi

[[ -s "${IB_DIR}/Makefile" && -s "${IB_DIR}/repositories" ]] \
    || die "ImageBuilder extraction is incomplete."

mkdir -p "${IB_DIR}/keys" "${IB_DIR}/packages"

# ============================================================
# Repository functions
# ============================================================

ensure_repo() {
    local repo="$1"

    grep -qxF -- "$repo" "${IB_DIR}/repositories" \
        || printf '%s\n' "$repo" >> "${IB_DIR}/repositories"
}

download_nonempty() {
    local url="$1"
    local output="$2"
    local description="$3"

    log "Downloading ${description}"

    curl -fL --retry 3 --retry-delay 2 "$url" -o "$output" \
        || die "Download failed: ${description} (${url})"

    [[ -s "$output" ]] || die "Downloaded file is empty: ${description}"
}

# ============================================================
# Clean ImageBuilder before adding local packages
# ============================================================

log "Cleaning ImageBuilder cache..."

make -C "$IB_DIR" clean \
    > "${WORK_DIR}/clean.log" 2>&1 \
    || die "ImageBuilder clean failed. See ${WORK_DIR}/clean.log"

# ============================================================
# YAOF repository
# ============================================================

KEY_URL="https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub"

FEED_URL="https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb"

download_nonempty \
    "$KEY_URL" \
    "${IB_DIR}/keys/custom-feed.rsa.pub" \
    "YAOF signing key"

TMP_INDEX="${WORK_DIR}/repo-check-yaof.adb"

download_nonempty \
    "$FEED_URL" \
    "$TMP_INDEX" \
    "YAOF APK index"

rm -f "$TMP_INDEX"

ensure_repo "$FEED_URL"

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

for item in \
    "passwall-luci:${PASSWALL_LUCI}" \
    "passwall-packages:${PASSWALL_PACKAGES}" \
    "passwall2:${PASSWALL2}"
do
    name="${item%%:*}"
    url="${item#*:}"

    TMP_INDEX="${WORK_DIR}/repo-check-${name}.adb"

    download_nonempty "$url" "$TMP_INDEX" "${name} APK index"

    rm -f "$TMP_INDEX"

    ensure_repo "$url"
done

# ============================================================
# OpenClash release
# ============================================================

if [[ "$OPENCLASH_TAG" == "latest" ]]; then
    OPENCLASH_API="https://api.github.com/repos/vernesong/OpenClash/releases/latest"
else
    OPENCLASH_API="https://api.github.com/repos/vernesong/OpenClash/releases/tags/${OPENCLASH_TAG}"
fi

RELEASE_JSON="${WORK_DIR}/openclash-release.json"

download_nonempty \
    "$OPENCLASH_API" \
    "$RELEASE_JSON" \
    "OpenClash release metadata"

OPENCLASH_INFO="$(
python3 - "$RELEASE_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    release = json.load(f)

if release.get("draft") or release.get("prerelease"):
    raise SystemExit("Refusing draft/prerelease OpenClash release")

assets = [
    a for a in release.get("assets", [])
    if a.get("name", "").startswith("luci-app-openclash-")
    and a.get("name", "").endswith(".apk")
]

if len(assets) != 1:
    raise SystemExit("Expected exactly one OpenClash APK asset in release")

a = assets[0]

print("\t".join([
    release.get("tag_name", ""),
    a.get("name", ""),
    a.get("browser_download_url", ""),
    a.get("digest") or ""
]))
PY
)" || die "Unable to parse OpenClash release metadata."

IFS=$'\t' read -r \
    OPENCLASH_RESOLVED_TAG \
    OPENCLASH_ASSET \
    OPENCLASH_URL \
    OPENCLASH_DIGEST <<< "$OPENCLASH_INFO"

[[ -n "$OPENCLASH_RESOLVED_TAG" ]] || die "OpenClash tag is missing."
[[ -n "$OPENCLASH_ASSET" ]] || die "OpenClash APK filename is missing."
[[ -n "$OPENCLASH_URL" ]] || die "OpenClash APK URL is missing."

OPENCLASH_VERSION="${OPENCLASH_RESOLVED_TAG#v}"

rm -f "${IB_DIR}/packages/"luci-app-openclash-*.apk

OPENCLASH_APK="${IB_DIR}/packages/${OPENCLASH_ASSET}"

download_nonempty \
    "$OPENCLASH_URL" \
    "$OPENCLASH_APK" \
    "OpenClash ${OPENCLASH_RESOLVED_TAG} APK"

if [[ "$OPENCLASH_DIGEST" == sha256:* ]]; then

    EXPECTED_SHA="${OPENCLASH_DIGEST#sha256:}"
    ACTUAL_SHA="$(sha256sum "$OPENCLASH_APK" | awk '{print $1}')"

    [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] \
        || die "OpenClash APK SHA256 verification failed."

    log "OpenClash APK SHA256 verified."

else
    log "WARNING: GitHub release did not provide a SHA256 digest."
fi

log "OpenClash release selected: ${OPENCLASH_RESOLVED_TAG}"

[[ -s "$OPENCLASH_APK" ]] || die "OpenClash APK is missing."

log "OpenClash APK is ready: $(du -h "$OPENCLASH_APK" | awk '{print $1}')"

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
# YAOF helper
# ============================================================

mkdir -p "${OVERLAY_DIR}/usr/bin"

FUCK_URL="https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh"

download_nonempty \
    "$FUCK_URL" \
    "${OVERLAY_DIR}/usr/bin/fuck" \
    "YAOF clean-overlay utility"

chmod 0755 "${OVERLAY_DIR}/usr/bin/fuck"

# ============================================================
# APK signing keys and runtime repositories
# ============================================================

mkdir -p \
    "${OVERLAY_DIR}/etc/apk/keys" \
    "${OVERLAY_DIR}/etc/apk/repositories.d"

cp -f \
    "${IB_DIR}/keys/custom-feed.rsa.pub" \
    "${OVERLAY_DIR}/etc/apk/keys/"

cp -f \
    "${IB_DIR}/keys/openwrt-passwall-build.pem" \
    "${OVERLAY_DIR}/etc/apk/keys/"

cat > "${OVERLAY_DIR}/etc/apk/repositories.d/customfeeds.list" <<EOF_REPOS
${FEED_URL}
${PASSWALL_LUCI}
${PASSWALL_PACKAGES}
${PASSWALL2}
EOF_REPOS

if [[ "$TARGET" == "rockchip" ]]; then

    mkdir -p "${OVERLAY_DIR}/etc/apk"

    ARCH_FILE="${OVERLAY_DIR}/etc/apk/arch"

    touch "$ARCH_FILE"

    grep -qxF "aarch64_generic" "$ARCH_FILE" \
        || printf '%s\n' "aarch64_generic" >> "$ARCH_FILE"
fi

# ============================================================
# Load package profiles
# ============================================================

load_packages() {
    local file="$1"

    [[ -f "$file" ]] || die "Package profile not found: ${file}"

    awk '
    {
        sub(/\r$/, "")
        sub(/[[:space:]]+#.*/, "")

        if ($0 ~ /^[[:space:]]*#/) next

        gsub(/^[ \t]+|[ \t]+$/, "")

        if ($0 != "") print
    }' "$file" | tr '\n' ' '
}

PACKAGES_COMMON="${ROOT_DIR}/profiles/packages.common"
PACKAGES_CUSTOM="${ROOT_DIR}/profiles/${PACKAGES_PROFILE}"

PACKAGES="$(load_packages "$PACKAGES_COMMON") $(load_packages "$PACKAGES_CUSTOM")"

# Required proxy packages
PACKAGES="${PACKAGES} luci-app-openclash luci-app-passwall luci-i18n-passwall-zh-cn"

# ============================================================
# De-duplicate packages
# ============================================================

declare -A SEEN_PACKAGES=()

DEDUPED_PACKAGES=()

for pkg in $PACKAGES; do

    if [[ -z "${SEEN_PACKAGES[$pkg]+x}" ]]; then
        SEEN_PACKAGES["$pkg"]=1
        DEDUPED_PACKAGES+=("$pkg")
    fi

done

PACKAGES="${DEDUPED_PACKAGES[*]}"

# ============================================================
# Required package validation
# ============================================================

REQUIRED_PACKAGES=(
    luci-app-openclash
    luci-app-passwall
    luci-i18n-passwall-zh-cn
)

for required in "${REQUIRED_PACKAGES[@]}"; do

    for pkg in $PACKAGES; do
        [[ "$pkg" != "-${required}" ]] \
            || die "Required package is explicitly excluded: ${required}"
    done

    [[ " $PACKAGES " == *" ${required} "* ]] \
        || die "Required package missing from package list: ${required}"

done

log "Package profile: ${PACKAGES_PROFILE}"
log "OpenClash: ${OPENCLASH_RESOLVED_TAG}"
log "PassWall: ${PASSWALL_RELEASE} feed"

# ============================================================
# Build firmware
# ============================================================

log "============================================================"
log "Starting ImageBuilder firmware build"
log "OpenWrt: ${VERSION}"
log "Architecture: ${ARCH}"
log "Profile: ${PROFILE}"
log "OpenClash: ${OPENCLASH_RESOLVED_TAG}"
log "PassWall: enabled"
log "============================================================"

log "OpenClash APK is in ImageBuilder packages directory."
log "ImageBuilder will handle local APK indexing during image build."

if ! make -C "$IB_DIR" image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES="$OVERLAY_DIR" \
    ROOTFS_PARTSIZE="1024" \
    2>&1 | tee "$BUILD_LOG"
then
    tail -n 100 "$BUILD_LOG" >&2 || true
    die "Firmware build failed. See ${BUILD_LOG}"
fi

# ============================================================
# Check plugin file errors
# ============================================================

if grep -E \
    '(/lib/functions\.sh: No such file|/lib/functions/network\.sh: No such file|/usr/share/openclash/.*No such file|/usr/share/passwall/.*No such file)' \
    "$BUILD_LOG" >/dev/null 2>&1
then

    tail -n 80 "$BUILD_LOG" >&2 || true

    die "OpenClash/PassWall missing-file warnings detected. Check ${BUILD_LOG}."
fi

# ============================================================
# Locate firmware output
# ============================================================

IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"

[[ -d "$IB_BIN_DIR" ]] || die "Output directory not found: ${IB_BIN_DIR}"

DATE_STR="$(date +%Y-%m-%d)"

PLATFORM_LABEL="$(
    echo "$PROFILE" \
    | sed 's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/'
)"

MATCH_PATTERN="*sysupgrade.img.gz"

if [[ "$TARGET" == "x86" ]]; then
    MATCH_PATTERN="*combined-efi.img.gz"
fi

# ============================================================
# Copy firmware
# ============================================================

IMAGE_COUNT=0

while IFS= read -r -d '' img; do

    fname="$(basename "$img")"

    clean_suffix="$(
        echo "$fname" \
        | sed -E "s/^openwrt-.*-${TARGET}-${SUBTARGET}-${PROFILE}-//"
    )"

    out_name="YAOF-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${clean_suffix}"

    cp -f "$img" "${OUTPUT_DIR}/${out_name}"

    log "Saved: ${out_name}"

    IMAGE_COUNT=$((IMAGE_COUNT + 1))

done < <(
    find "$IB_BIN_DIR" -type f -name "$MATCH_PATTERN" -print0
)

(( IMAGE_COUNT > 0 )) || die "No firmware image found: ${MATCH_PATTERN}"

# ============================================================
# Build summary
# ============================================================

log "============================================================"
log "Build completed successfully."
log "OpenWrt: ${VERSION}"
log "Target: ${TARGET}/${SUBTARGET}"
log "Profile: ${PROFILE}"
log "OpenClash: ${OPENCLASH_RESOLVED_TAG}"
log "PassWall: enabled"
log "PassWall Chinese translation: enabled"
log "Firmware images generated: ${IMAGE_COUNT}"
log "Build log: ${BUILD_LOG}"
log "Output directory: ${OUTPUT_DIR}"
log "============================================================"

ls -lh "${OUTPUT_DIR}/"
