#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LXC="/snap/bin/lxc"
OS_NAME="unknown"
PKG_MANAGER="unknown"

ok() { echo -e "${GREEN}[OK]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

reading() {
    read -rp "$(echo -e "${GREEN}[INPUT]${NC} $1")" "$2"
}

detect_system() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_NAME="${PRETTY_NAME:-${ID:-unknown}}"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    fi

    ok "系统: $OS_NAME"
    ok "包管理器: $PKG_MANAGER"
}

detect_arch() {
    local sys_arch
    sys_arch=$(uname -m)
    case $sys_arch in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            err "不支持的架构: $sys_arch"
            exit 1
            ;;
    esac
    ok "系统架构: ${sys_arch} -> 镜像架构: $ARCH"
}

install_packages() {
    if [ "$(id -u)" -ne 0 ]; then
        warn "当前不是 root，无法自动安装依赖"
        return 1
    fi

    case "$PKG_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        yum)
            yum install -y "$@"
            ;;
        zypper)
            zypper --non-interactive install "$@"
            ;;
        pacman)
            pacman -Sy --noconfirm "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

install_lxd() {
    if [ "$(id -u)" -ne 0 ]; then
        err "未找到 lxc，且当前不是 root，无法自动安装 LXD"
        return 1
    fi

    info "未找到 lxc，按照当前系统自动安装 LXD..."

    if ! command -v snap >/dev/null 2>&1; then
        info "安装 snapd..."
        install_packages snapd || return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now snapd.socket >/dev/null 2>&1 || true
        systemctl start snapd >/dev/null 2>&1 || true
    fi

    if [ -d /var/lib/snapd/snap ] && [ ! -e /snap ]; then
        ln -s /var/lib/snapd/snap /snap
    fi

    if ! command -v snap >/dev/null 2>&1; then
        err "snapd 安装后仍不可用，无法自动安装 LXD"
        return 1
    fi

    snap wait system seed.loaded >/dev/null 2>&1 || true

    if snap list lxd >/dev/null 2>&1; then
        return 0
    fi

    snap install lxd
}

ensure_lxc() {
    if [ -x "$LXC" ]; then
        ok "LXD 命令: $LXC"
        return
    fi

    if command -v lxc >/dev/null 2>&1; then
        LXC="$(command -v lxc)"
        ok "LXD 命令: $LXC"
        return
    fi

    install_lxd || {
        err "LXD 自动安装失败，请先手动安装并初始化 LXD"
        exit 1
    }

    if [ -x "$LXC" ]; then
        ok "LXD 命令: $LXC"
        return
    fi

    if command -v lxc >/dev/null 2>&1; then
        LXC="$(command -v lxc)"
        ok "LXD 命令: $LXC"
        return
    fi

    err "LXD 安装后仍未找到 lxc 命令，请重新登录 shell 或检查 snapd"
    exit 1
}

install_download_tools() {
    info "按照当前系统自动安装下载工具 wget/curl..."
    install_packages wget curl ca-certificates
}

ensure_downloader() {
    if command -v wget >/dev/null 2>&1; then
        ok "下载工具: $(command -v wget)"
        return
    fi

    if command -v curl >/dev/null 2>&1; then
        ok "下载工具: $(command -v curl)"
        return
    fi

    if ! install_download_tools; then
        err "未找到 wget 或 curl，请先安装其中一个"
        exit 1
    fi

    if command -v wget >/dev/null 2>&1; then
        ok "下载工具: $(command -v wget)"
        return
    fi

    if command -v curl >/dev/null 2>&1; then
        ok "下载工具: $(command -v curl)"
        return
    fi

    err "wget/curl 安装后仍不可用，请检查 PATH"
    exit 1
}

download_file() {
    local output="$1"
    local url="$2"

    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$output" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$output" "$url"
    else
        return 1
    fi
}

UPSTREAM_OWNER_A="xka"
UPSTREAM_OWNER_B="tld"
IMAGES_BASE_URL="https://github.com/${UPSTREAM_OWNER_A}${UPSTREAM_OWNER_B}/lxdapi-web-server/releases/download/image"

declare -a IMAGE_LIST=(
    "almalinux-8"
    "almalinux-9"
    "alpine-320"
    "alpine-321"
    "alpine-322"
    "archlinux-latest"
    "centos-9-Stream"
    "debian-11"
    "debian-12"
    "debian-13"
    "fedora-42"
    "fedora-43"
    "opensuse-156"
    "opensuse-tumbleweed"
    "rockylinux-8"
    "rockylinux-9"
    "ubuntu-2204"
    "ubuntu-2404"
)

download_and_import() {
    local image_name="$1"
    local image_type="$2"
    local image_url="${IMAGES_BASE_URL}/${image_name}-${ARCH}-${image_type}.tar.gz"
    local temp_file
    temp_file=$(mktemp)

    info "下载: ${image_name}-${ARCH}-${image_type}.tar.gz"

    if download_file "$temp_file" "$image_url"; then
        info "导入到 LXD..."
        local alias="${image_name}-${image_type}"
        if "$LXC" image import "$temp_file" --alias "$alias" 2>/dev/null; then
            ok "成功导入: $alias"
        else
            warn "导入失败: $alias"
        fi
    else
        warn "下载失败: ${image_name}-${ARCH}-${image_type}"
    fi

    rm -f "$temp_file"
}

show_image_list() {
    echo
    echo "============================================================================================================"
    echo " 1) almalinux-8        2) almalinux-9       3) alpine-320        4) alpine-321        5) alpine-322"
    echo " 6) archlinux-latest   7) centos-9-Stream   8) debian-11         9) debian-12        10) debian-13"
    echo "11) fedora-42         12) fedora-43        13) opensuse-156     14) opensuse-tumbleweed"
    echo "15) rockylinux-8      16) rockylinux-9     17) ubuntu-2204      18) ubuntu-2404"
    echo "============================================================================================================"
    echo
}

menu_import() {
    echo
    info "=== 导入镜像 ==="
    show_image_list

    reading "输入编号，多个用逗号分隔，或 all 全部导入 [8,9,17,18]: " image_choices
    image_choices=${image_choices:-"8,9,17,18"}

    while true; do
        reading "选择镜像类型 lxc/kvm [lxc]: " image_type
        image_type=${image_type:-lxc}
        if [[ "$image_type" =~ ^(lxc|kvm)$ ]]; then
            break
        else
            warn "请输入 lxc 或 kvm"
        fi
    done

    if [[ "$image_type" == "kvm" && "$ARCH" == "arm64" ]]; then
        warn "KVM 镜像不支持 arm64 架构"
        return
    fi

    if [[ "$image_choices" == "all" ]]; then
        selected_images=("${IMAGE_LIST[@]}")
    else
        IFS=',' read -ra choices <<< "$image_choices"
        selected_images=()
        for choice in "${choices[@]}"; do
            choice=$(echo "$choice" | xargs)
            if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
                continue
            fi
            idx=$((choice - 1))
            if [[ $idx -ge 0 && $idx -lt ${#IMAGE_LIST[@]} ]]; then
                selected_images+=("${IMAGE_LIST[$idx]}")
            fi
        done
    fi

    if [[ ${#selected_images[@]} -eq 0 ]]; then
        warn "未选择任何镜像"
        return
    fi

    ok "已选择 ${#selected_images[@]} 个镜像 (${image_type})"
    echo

    current=0
    for img in "${selected_images[@]}"; do
        current=$((current + 1))
        echo "[$current/${#selected_images[@]}]"
        download_and_import "$img" "$image_type"
        echo
    done
}

menu_list() {
    echo
    info "=== 已有镜像 ==="
    "$LXC" image list
}

menu_delete() {
    echo
    info "=== 删除镜像 ==="
    "$LXC" image list
    echo
    reading "输入要删除的镜像别名或指纹: " image_id
    if [ -z "$image_id" ]; then
        return
    fi

    warn "确认删除镜像 $image_id？"
    reading "确认？(y/n) [n]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        if "$LXC" image delete "$image_id"; then
            ok "镜像已删除"
        else
            err "删除失败"
        fi
    else
        info "已取消"
    fi
}

main_menu() {
    while true; do
        echo
        echo "================================"
        echo "      LXD 镜像管理脚本"
        echo "        LXDAPI by Sakura"
        echo "================================"
        echo "1. 导入镜像"
        echo "2. 查看已有镜像"
        echo "3. 删除镜像"
        echo "0. 退出"
        echo "================================"
        reading "请选择 [0-3]: " choice

        case "$choice" in
            1) menu_import ;;
            2) menu_list ;;
            3) menu_delete ;;
            0) ok "退出"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

detect_system
detect_arch
ensure_lxc
ensure_downloader
main_menu
