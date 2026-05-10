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

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 用户运行"
    fi
}

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
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y curl wget ca-certificates >/dev/null 2>&1 || true
    fi
}

ensure_downloader() {
    if find_bin curl >/dev/null 2>&1 || find_bin wget >/dev/null 2>&1; then
        return 0
    fi

    info "未找到 curl/wget，正在安装下载工具..."
    install_downloader

    if ! find_bin curl >/dev/null 2>&1 && ! find_bin wget >/dev/null 2>&1; then
        err "无法安装 curl/wget，请先手动安装下载工具"
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
    shift || true
    local url="${BASE_URL}/${name}"
    local tmp
    tmp=$(mktemp)

    info "下载 ${name}..."
    if ! download_file "$url" "$tmp"; then
        rm -f "$tmp"
        err "下载失败: $url"
    fi

    chmod +x "$tmp"
    bash "$tmp" "$@"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

show_header() {
    echo
    echo "========================================"
    echo "        Sakura 安装管理脚本"
    echo "========================================"
    echo
}

show_menu() {
    echo "1. 一键完整安装（LXD + Sakura 面板 + 导入镜像）"
    echo "2. 只安装/配置 LXD"
    echo "3. 只安装 Sakura 面板"
    echo "4. 导入 LXD 镜像"
    echo "5. 更新 Sakura 面板"
    echo "6. 卸载 Sakura 面板"
    echo "7. 修复运行环境（清理残留服务器 / 关闭 ACME）"
    echo "0. 退出"
    echo
}

run_full_install() {
    run_remote_script "lxd_install.sh" || err "LXD 安装失败"
    run_remote_script "lxdapi_install.sh" || err "面板安装失败"
    run_remote_script "image_import.sh" || err "镜像导入脚本执行失败"
    ok "一键完整安装流程执行完成"
    print_urls
}

install_lxd_only() {
    run_remote_script "lxd_install.sh" || err "LXD 安装失败"
}

install_panel_only() {
    run_remote_script "lxdapi_install.sh" || err "面板安装失败"
    print_urls
}

import_images_only() {
    run_remote_script "image_import.sh" || err "镜像导入脚本执行失败"
}

update_panel_only() {
    run_remote_script "lxdapi_update.sh" || err "面板更新失败"
    print_urls
}

uninstall_panel_only() {
    warn "卸载只会删除 Sakura/LXDAPI 面板，不会删除 LXD、镜像和已创建的服务器。"
    run_remote_script "lxdapi_uninstall.sh" || err "面板卸载失败"
}

repair_runtime() {
    local instance_name="${1:-}"
    if [ -z "$instance_name" ]; then
        reading "请输入要清理的残留服务器名，留空只修复 ACME 和服务状态：" instance_name
    fi

    if [ -n "$instance_name" ]; then
        warn "将检查并删除 LXD 中名为 ${instance_name} 的残留实例。"
    fi

    run_remote_script "fix_lxdapi_runtime.sh" "$instance_name" || err "运行环境修复失败"
}

print_urls() {
    echo
    info "后台登录地址: https://服务器IP:8443/admin/login"
    info "WHMCS API: https://服务器IP:8443/api/system/containers"
}

run_choice() {
    local choice="$1"
    shift || true
    case "$choice" in
        1|install|all)
            run_full_install
            ;;
        2|lxd)
            install_lxd_only
            ;;
        3|panel|install-panel)
            install_panel_only
            ;;
        4|image|images|import)
            import_images_only
            ;;
        5|update)
            update_panel_only
            ;;
        6|uninstall|remove)
            uninstall_panel_only
            ;;
        7|repair|fix)
            repair_runtime "${1:-}"
            ;;
        0|exit|quit)
            info "已退出"
            exit 0
            ;;
        *)
            err "无效选择: $choice"
            ;;
    esac
}

main() {
    require_root
    ensure_downloader
    show_header

    if [ -n "${1:-}" ]; then
        run_choice "$@"
        exit 0
    fi

    show_menu
    reading "请选择 [1-7]，默认一键完整安装 [1]：" choice
    choice=${choice:-1}
    run_choice "$choice"
}

main "$@"
