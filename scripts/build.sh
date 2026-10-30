```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# YAOF OpenWrt ImageBuilder
# OpenWrt 25.12.x / x86_64
#
# 集成：
#   - OpenClash 最新正式版
#   - PassWall
#   - PassWall 中文包
#   - YAOF 自定义 feed
#   - 用户 profiles 软件包清单
#
# 用法：
#   ./scripts/build.sh <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]
#
# 示例：
#   ./scripts/build.sh x86 64 generic default 25.12.6
# ============================================================

TARGET="${1:-}"
SUBTARGET="${2:-}"
PROFILE="${3:-}"
PACKAGES_PROFILE="${4:-}"
REQUESTED_VERSION="${5:-25.12.6}"

if [[ -z "$TARGET" || -z "$SUBTARGET" || -z "$PROFILE" || -z "$PACKAGES_PROFILE" ]]; then
    echo "用法: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION]" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="${ROOT_DIR}/profiles"
ARTIFACT_DIR="${ROOT_DIR}/artifact"
WORK_DIR="${ROOT_DIR}/work"

IMAGEBUILDER_BASE="https://downloads.openwrt.org"
YAOF_BASE="https://qiusimons.github.io/OpenWrt-Add"

OPENCLASH_API="https://api.github.com/repos/vernesong/OpenClash/releases/latest"
PASSWALL_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build"

OPENCLASH_PACKAGE="luci-app-openclash"
PASSWALL_PACKAGE="luci-app-passwall"
PASSWALL_I18N_PACKAGE="luci-i18n-passwall-zh-cn"

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
    log "错误：$*"
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

for cmd in curl tar sha256sum python3 awk sed grep find sort paste; do
    need_command "$cmd"
done

mkdir -p "$WORK_DIR" "$ARTIFACT_DIR"

# ------------------------------------------------------------
# 检查 OpenWrt 版本
# ------------------------------------------------------------

resolve_version() {
    local requested="$1"
    local target_url

    if [[ "$requested" == "25.12" ]]; then
        log "正在查询 OpenWrt 25.12 系列可用版本..."

        requested="$(
            curl -fsSL "${IMAGEBUILDER_BASE}/releases/" |
            python3 -c '
import re
import sys

html = sys.stdin.read()
versions = set(
    re.findall(r"href=[\"\\x27]([0-9]+\\.[0-9]+\\.[0-9]+)/[\"\\x27]", html)
)

versions = [
    v for v in versions
    if v.startswith("25.12.")
]

versions.sort(key=lambda x: tuple(map(int, x.split("."))))

print(versions[-1] if versions else "")
'
        )"

        [[ -n "$requested" ]] || die "无法获取 OpenWrt 25.12.x 版本"
    fi

    [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "版本格式不正确：$requested"

    target_url="${IMAGEBUILDER_BASE}/releases/${requested}/targets/${TARGET}/${SUBTARGET}/"

    log "检查 ImageBuilder 是否存在：${requested}"

    curl -fsSL "$target_url" >/dev/null ||
        die "官方目录中不存在该版本或目标架构：${target_url}"

    printf '%s\n' "$requested"
}

VERSION="$(resolve_version "$REQUESTED_VERSION")"

log "使用 OpenWrt 版本：${VERSION}"

# ------------------------------------------------------------
# 架构映射
# ------------------------------------------------------------

case "${TARGET}/${SUBTARGET}" in
    x86/64)
        ARCH="x86_64"
        ;;
    rockchip/armv8)
        ARCH="aarch64_generic"
        ;;
    mediatek/filogic)
        ARCH="aarch64_cortex-a53"
        ;;
    *)
        die "尚未配置该目标的 PassWall 第三方 feed 架构：${TARGET}/${SUBTARGET}"
        ;;
esac

IMAGEBUILDER_NAME="openwrt-imagebuilder-${VERSION}-${TARGET}-${SUBTARGET}.Linux-x86_64.tar.zst"

IMAGEBUILDER_URL="${IMAGEBUILDER_BASE}/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IMAGEBUILDER_NAME}"

IB_ARCHIVE="${WORK_DIR}/${IMAGEBUILDER_NAME}"
IB_DIR="${WORK_DIR}/imagebuilder-${VERSION}-${TARGET}-${SUBTARGET}"

# ------------------------------------------------------------
# 下载并解压 ImageBuilder
# ------------------------------------------------------------

if [[ ! -d "$IB_DIR" ]]; then

    log "下载 ImageBuilder：${IMAGEBUILDER_URL}"

    curl -fL --retry 3 --retry-delay 2 \
        "$IMAGEBUILDER_URL" \
        -o "$IB_ARCHIVE"

    log "解压 ImageBuilder..."

    if [[ "$IB_ARCHIVE" == *.tar.zst ]]; then
        need_command zstd
        tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$WORK_DIR"
    else
        tar -xf "$IB_ARCHIVE" -C "$WORK_DIR"
    fi

    EXTRACTED_DIR="$(
        find "$WORK_DIR" -maxdepth 1 -type d \
            -name "openwrt-imagebuilder-${VERSION}-${TARGET}-${SUBTARGET}*" |
        head -n 1
    )"

    [[ -n "$EXTRACTED_DIR" ]] ||
        die "ImageBuilder 解压后目录不存在"

    mv "$EXTRACTED_DIR" "$IB_DIR"
fi

[[ -f "${IB_DIR}/Makefile" ]] ||
    die "ImageBuilder Makefile 不存在"

mkdir -p \
    "${IB_DIR}/packages" \
    "${IB_DIR}/keys" \
    "${IB_DIR}/files"

# ------------------------------------------------------------
# YAOF 自定义 feed
# ------------------------------------------------------------

log "配置 YAOF feed..."

YAOF_KEY_URL="${YAOF_BASE}/keys/custom-feed.rsa.pub"
YAOF_REPO_URL="${YAOF_BASE}/${ARCH}/packages.adb"

curl -fL --retry 3 \
    "$YAOF_KEY_URL" \
    -o "${IB_DIR}/keys/custom-feed.rsa.pub"

mkdir -p "${IB_DIR}/files/etc/apk/keys"
mkdir -p "${IB_DIR}/files/etc/apk/repositories.d"

cp "${IB_DIR}/keys/custom-feed.rsa.pub" \
   "${IB_DIR}/files/etc/apk/keys/custom-feed.rsa.pub"

CUSTOM_FEEDS="${IB_DIR}/files/etc/apk/repositories.d/customfeeds.list"

touch "$CUSTOM_FEEDS"

if ! grep -Fqx "$YAOF_REPO_URL" "$CUSTOM_FEEDS"; then
    printf '%s\n' "$YAOF_REPO_URL" >> "$CUSTOM_FEEDS"
fi

# ------------------------------------------------------------
# PassWall feed 和公钥
# ------------------------------------------------------------

log "配置 PassWall 25.12 软件源..."

PASSWALL_RELEASE="${VERSION%.*}"

PASSWALL_KEY_URL="${PASSWALL_BASE}/apk.pub"
PASSWALL_KEY="${IB_DIR}/keys/openwrt-passwall-build.pem"

curl -fL --retry 3 \
    "$PASSWALL_KEY_URL" \
    -o "$PASSWALL_KEY"

mkdir -p "${IB_DIR}/files/etc/apk/keys"

cp "$PASSWALL_KEY" \
   "${IB_DIR}/files/etc/apk/keys/openwrt-passwall-build.pem"

PASSWALL_LUCI_REPO="${PASSWALL_BASE}/releases/packages-${PASSWALL_RELEASE}/${ARCH}/passwall_luci/packages.adb"

PASSWALL_CORE_REPO="${PASSWALL_BASE}/releases/packages-${PASSWALL_RELEASE}/${ARCH}/passwall_packages/packages.adb"

PASSWALL_REPO_FILE="${IB_DIR}/files/etc/apk/repositories.d/passwall.list"

touch "$PASSWALL_REPO_FILE"

for repo in "$PASSWALL_LUCI_REPO" "$PASSWALL_CORE_REPO"; do
    if ! grep -Fqx "$repo" "$PASSWALL_REPO_FILE"; then
        printf '%s\n' "$repo" >> "$PASSWALL_REPO_FILE"
    fi
done

# ImageBuilder 构建阶段使用的软件源配置
IB_REPOSITORIES="${IB_DIR}/repositories"

touch "$IB_REPOSITORIES"

for repo in "$PASSWALL_LUCI_REPO" "$PASSWALL_CORE_REPO"; do
    if ! grep -Fqx "$repo" "$IB_REPOSITORIES"; then
        printf '%s\n' "$repo" >> "$IB_REPOSITORIES"
    fi
done

# ------------------------------------------------------------
# OpenClash 最新正式版
# ------------------------------------------------------------

log "查询 OpenClash 最新正式版..."

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
    raise SystemExit("最新 Release 不是正式版")

assets = data.get("assets", [])

matches = [
    a for a in assets
    if a.get("name", "").startswith("luci-app-openclash-")
    and a.get("name", "").endswith(".apk")
]

if not matches:
    raise SystemExit("没有找到 OpenClash APK")

asset = matches[0]
digest = asset.get("digest") or ""

if not digest.startswith("sha256:"):
    raise SystemExit("GitHub Release 没有提供 SHA256 digest")

print(data.get("tag_name", ""))
print(asset.get("name", ""))
print(asset.get("browser_download_url", ""))
print(digest.split(":", 1)[1])
'
)" || die "获取 OpenClash 正式版信息失败"

OPENCLASH_TAG="$(printf '%s\n' "$OPENCLASH_INFO" | sed -n '1p')"
OPENCLASH_APK_NAME="$(printf '%s\n' "$OPENCLASH_INFO" | sed -n '2p')"
OPENCLASH_APK_URL="$(printf '%s\n' "$OPENCLASH_INFO" | sed -n '3p')"
OPENCLASH_EXPECTED_SHA256="$(printf '%s\n' "$OPENCLASH_INFO" | sed -n '4p')"

[[ -n "$OPENCLASH_TAG" ]] ||
    die "OpenClash 版本号为空"

[[ -n "$OPENCLASH_APK_URL" ]] ||
    die "OpenClash APK 下载地址为空"

[[ "$OPENCLASH_APK_NAME" == luci-app-openclash-*.apk ]] ||
    die "OpenClash APK 文件名不符合预期"

log "OpenClash 版本：${OPENCLASH_TAG}"

# 下载到临时目录
OPENCLASH_TEMP_DIR="${WORK_DIR}/openclash"

mkdir -p "$OPENCLASH_TEMP_DIR"

OPENCLASH_TEMP_APK="${OPENCLASH_TEMP_DIR}/${OPENCLASH_APK_NAME}"

curl -fL --retry 3 \
    "$OPENCLASH_APK_URL" \
    -o "$OPENCLASH_TEMP_APK"

# 校验 GitHub 提供的 SHA256
OPENCLASH_ACTUAL_SHA256="$(
    sha256sum "$OPENCLASH_TEMP_APK" | awk '{print $1}'
)"

if [[ "$OPENCLASH_ACTUAL_SHA256" != "$OPENCLASH_EXPECTED_SHA256" ]]; then
    die "OpenClash APK SHA256 校验失败"
fi

log "OpenClash APK SHA256 校验通过"

# ------------------------------------------------------------
# 放入 ImageBuilder 本地 packages 目录
#
# 不手动运行 apk index。
# 不创建 file:// 仓库。
# 由 ImageBuilder 自身处理本地 packages 目录。
# ------------------------------------------------------------

OPENCLASH_APK="${IB_DIR}/packages/${OPENCLASH_APK_NAME}"

cp -f "$OPENCLASH_TEMP_APK" "$OPENCLASH_APK"

[[ -s "$OPENCLASH_APK" ]] ||
    die "OpenClash APK 复制失败或文件为空"

log "OpenClash APK 已放入 ImageBuilder packages 目录"

# ------------------------------------------------------------
# Overlay 文件
# ------------------------------------------------------------

if [[ -d "${ROOT_DIR}/files" ]]; then
    log "复制用户 overlay 文件..."
    cp -a "${ROOT_DIR}/files/." "${IB_DIR}/files/"
fi

# 确保签名公钥在最终固件 overlay 中
mkdir -p "${IB_DIR}/files/etc/apk/keys"

cp "$PASSWALL_KEY" \
   "${IB_DIR}/files/etc/apk/keys/openwrt-passwall-build.pem"

cp "${IB_DIR}/keys/custom-feed.rsa.pub" \
   "${IB_DIR}/files/etc/apk/keys/custom-feed.rsa.pub"

# 确保 YAOF feed 配置存在
mkdir -p "${IB_DIR}/files/etc/apk/repositories.d"

CUSTOM_FEEDS="${IB_DIR}/files/etc/apk/repositories.d/customfeeds.list"

touch "$CUSTOM_FEEDS"

if ! grep -Fqx "$YAOF_REPO_URL" "$CUSTOM_FEEDS"; then
    printf '%s\n' "$YAOF_REPO_URL" >> "$CUSTOM_FEEDS"
fi

# 确保 PassWall feed 配置存在
PASSWALL_REPO_FILE="${IB_DIR}/files/etc/apk/repositories.d/passwall.list"

touch "$PASSWALL_REPO_FILE"

for repo in "$PASSWALL_LUCI_REPO" "$PASSWALL_CORE_REPO"; do
    if ! grep -Fqx "$repo" "$PASSWALL_REPO_FILE"; then
        printf '%s\n' "$repo" >> "$PASSWALL_REPO_FILE"
    fi
done

# ------------------------------------------------------------
# YAOF clean-overlay.sh
# ------------------------------------------------------------

log "下载 YAOF clean-overlay.sh..."

mkdir -p "${IB_DIR}/files/usr/bin"

CLEAN_OVERLAY_URL="${YAOF_BASE}/clean-overlay.sh"

curl -fL --retry 3 \
    "$CLEAN_OVERLAY_URL" \
    -o "${IB_DIR}/files/usr/bin/fuck"

chmod +x "${IB_DIR}/files/usr/bin/fuck"

# ------------------------------------------------------------
# Rockchip 架构配置
# ------------------------------------------------------------

if [[ "$TARGET" == "rockchip" ]]; then

    mkdir -p "${IB_DIR}/files/etc/apk"

    touch "${IB_DIR}/files/etc/apk/arch"

    if ! grep -Fqx "aarch64_generic" "${IB_DIR}/files/etc/apk/arch"; then
        printf '%s\n' "aarch64_generic" \
            >> "${IB_DIR}/files/etc/apk/arch"
    fi
fi

# ------------------------------------------------------------
# 读取软件包清单
# ------------------------------------------------------------

load_packages() {
    local file="$1"

    [[ -f "$file" ]] || return 0

    sed \
        -e 's/\r$//' \
        -e 's/[[:space:]]*#.*$//' \
        "$file" |
    awk 'NF { print }'
}

COMMON_PACKAGES="${PROFILES_DIR}/packages.common"
PROFILE_PACKAGES="${PROFILES_DIR}/${PACKAGES_PROFILE}"

[[ -f "$COMMON_PACKAGES" ]] ||
    die "找不到公共软件包清单：${COMMON_PACKAGES}"

[[ -f "$PROFILE_PACKAGES" ]] ||
    die "找不到指定的软件包配置：${PROFILE_PACKAGES}"

log "读取公共软件包清单：${COMMON_PACKAGES}"
log "读取 profile 软件包清单：${PROFILE_PACKAGES}"

PACKAGES="$(
    {
        load_packages "$COMMON_PACKAGES"
        load_packages "$PROFILE_PACKAGES"

        # 强制加入三个 LuCI 软件包
        printf '%s\n' \
            "$OPENCLASH_PACKAGE" \
            "$PASSWALL_PACKAGE" \
            "$PASSWALL_I18N_PACKAGE"
    } |
    awk '!seen[$0]++' |
    paste -sd ' ' -
)"

[[ -n "$PACKAGES" ]] ||
    die "软件包清单为空"

log "本次请求安装的软件包："

printf '%s\n' "$PACKAGES" | tr ' ' '\n' >&2

# ------------------------------------------------------------
# 清理旧构建产物
# ------------------------------------------------------------

BIN_DIR="${IB_DIR}/bin"

rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"

# ------------------------------------------------------------
# 构建固件
# ------------------------------------------------------------

log "开始执行 ImageBuilder..."

cd "$IB_DIR"

make image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES="${IB_DIR}/files" \
    || die "ImageBuilder 构建失败。没有自动跳过或删除缺失软件包。"

# ------------------------------------------------------------
# 检查构建产物
# ------------------------------------------------------------

log "检查构建产物..."

if [[ "$TARGET" == "x86" ]]; then

    mapfile -t IMAGE_FILES < <(
        find "$BIN_DIR" -type f -name '*combined-efi.img.gz' | sort
    )

else

    mapfile -t IMAGE_FILES < <(
        find "$BIN_DIR" -type f -name '*sysupgrade.img.gz' | sort
    )

fi

if [[ "${#IMAGE_FILES[@]}" -eq 0 ]]; then
    die "make image 返回成功，但没有找到符合要求的固件文件"
fi

mkdir -p "$ARTIFACT_DIR"

for image_file in "${IMAGE_FILES[@]}"; do

    cp -f "$image_file" "$ARTIFACT_DIR/"

    log "已复制固件：${ARTIFACT_DIR}/$(basename "$image_file")"

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
    echo "PassWall: ${PASSWALL_PACKAGE}"
    echo "PassWall Translation: ${PASSWALL_I18N_PACKAGE}"
    echo "Packages Profile: ${PACKAGES_PROFILE}"
    echo "Build Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "Requested Packages:"
    printf '%s\n' "$PACKAGES" | tr ' ' '\n'
} > "${ARTIFACT_DIR}/build-info.txt"

log "构建流程结束"
log "固件输出目录：${ARTIFACT_DIR}"
```
