#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_URL="https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main"

log() { echo -e "$1"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; exit 1; }
reading() { read -rp "$(echo -e "${GREEN}$1${NC}")" "$2"; }

find_bin() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi

    for path in "/usr/bin/$name" "/bin/$name" "/usr/local/bin/$name" "/snap/bin/$name"; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

install_downloader() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 用户运行"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y curl wget ca-certificates >/dev/null 2>&1 || true
    fi
}

download_file() {
    local url="$1"
    local output="$2"

    local curl_bin
    curl_bin=$(find_bin curl || true)
    if [ -n "$curl_bin" ]; then
        "$curl_bin" -LfsS --retry 3 -o "$output" "$url"
        return $?
    fi

    local wget_bin
    wget_bin=$(find_bin wget || true)
    if [ -n "$wget_bin" ]; then
        "$wget_bin" -q --show-progress -O "$output" "$url"
        return $?
    fi

    return 127
}

run_remote_script() {
    local name="$1"
    local url="${BASE_URL}/${name}"
    local tmp
    tmp=$(mktemp)

    info "下载 ${name}..."
    if ! download_file "$url" "$tmp"; then
        rm -f "$tmp"
        err "下载失败: $url"
    fi

    chmod +x "$tmp"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

main() {
    echo
    echo "========================================"
    echo "        Sakura 一键安装脚本"
    echo "========================================"
    echo
    echo "1. 安装并配置 LXD"
    echo "2. 安装 Sakura 面板"
    echo "3. 导入 LXD 镜像"
    echo

    if ! find_bin curl >/dev/null 2>&1 && ! find_bin wget >/dev/null 2>&1; then
        info "未找到 curl/wget，正在安装下载工具..."
        install_downloader
    fi

    reading "是否安装并配置 LXD？(y/n) [y]：" install_lxd_confirm
    install_lxd_confirm=${install_lxd_confirm:-y}
    if [[ "$install_lxd_confirm" =~ ^[yY]$ ]]; then
        run_remote_script "lxd_install.sh" || err "LXD 安装失败"
    else
        warn "已跳过 LXD 安装"
    fi

    echo
    reading "是否安装 Sakura 面板？(y/n) [y]：" install_panel_confirm
    install_panel_confirm=${install_panel_confirm:-y}
    if [[ "$install_panel_confirm" =~ ^[yY]$ ]]; then
        run_remote_script "lxdapi_install.sh" || err "面板安装失败"
    else
        warn "已跳过面板安装"
    fi

    echo
    reading "是否导入镜像？(y/n) [y]：" import_image_confirm
    import_image_confirm=${import_image_confirm:-y}
    if [[ "$import_image_confirm" =~ ^[yY]$ ]]; then
        run_remote_script "image_import.sh" || err "镜像导入脚本执行失败"
    else
        warn "已跳过镜像导入"
    fi

    echo
    ok "一键流程执行完成"
    echo
    info "面板地址: https://服务器IP:8443/admin/login"
    info "WHMCS API: https://服务器IP:8443/api/system/containers"
}

main "$@"
