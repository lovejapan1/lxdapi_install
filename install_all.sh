#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_URL="https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main"
CONFIG_FILE="/opt/lxdapi/configs/config.yaml"
SERVICE_NAME="lxdapi"

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

ensure_lxc_path() {
    if [ -x /snap/bin/lxc ]; then
        ln -sf /snap/bin/lxc /usr/local/bin/lxc
        hash -r 2>/dev/null || true
        ok "已修复 lxc 路径: /usr/local/bin/lxc -> /snap/bin/lxc"
    fi
}

ensure_lxd_internal_ipv4() {
    ensure_lxc_path
    command -v lxc >/dev/null 2>&1 || return 0

    if ! lxc list >/dev/null 2>&1; then
        warn "LXD 暂未就绪，跳过内网 IPv4 修复"
        return 0
    fi

    if ! lxc network show lxdbr0 >/dev/null 2>&1; then
        info "创建 LXD 内网桥 lxdbr0..."
        lxc network create lxdbr0 ipv4.address=auto ipv4.nat=true ipv6.address=none >/dev/null 2>&1 || \
        lxc network create lxdbr0 ipv4.address=10.10.10.1/24 ipv4.nat=true ipv6.address=none >/dev/null 2>&1 || \
        err "创建 lxdbr0 失败"
    fi

    local ipv4_addr
    ipv4_addr=$(lxc network get lxdbr0 ipv4.address 2>/dev/null || true)
    if [ -z "$ipv4_addr" ] || [ "$ipv4_addr" = "none" ]; then
        lxc network set lxdbr0 ipv4.address auto >/dev/null 2>&1 || \
        lxc network set lxdbr0 ipv4.address 10.10.10.1/24 >/dev/null 2>&1 || \
        err "设置 lxdbr0 IPv4 地址失败"
    fi

    lxc network set lxdbr0 ipv4.dhcp true >/dev/null 2>&1 || true
    lxc network set lxdbr0 ipv4.nat true >/dev/null 2>&1 || true

    if lxc profile device show default 2>/dev/null | grep -q '^eth0:'; then
        lxc profile device set default eth0 network lxdbr0 >/dev/null 2>&1 || {
            lxc profile device remove default eth0 >/dev/null 2>&1 || true
            lxc profile device add default eth0 nic network=lxdbr0 name=eth0 >/dev/null 2>&1 || err "配置 default profile eth0 失败"
        }
        lxc profile device set default eth0 name eth0 >/dev/null 2>&1 || true
    else
        lxc profile device add default eth0 nic network=lxdbr0 name=eth0 >/dev/null 2>&1 || err "添加 default profile eth0 失败"
    fi

    if lxc storage show default >/dev/null 2>&1 && ! lxc profile device show default 2>/dev/null | grep -q '^root:'; then
        lxc profile device add default root disk path=/ pool=default >/dev/null 2>&1 || true
    fi

    ok "LXD 内网 IPv4 已启用，后续新服务器会从 lxdbr0 获取内网 IP"
}

list_lxd_instances() {
    command -v lxc >/dev/null 2>&1 || return 0
    lxc list --format csv -c n 2>/dev/null | sed '/^[[:space:]]*$/d' || true
}

offer_cleanup_existing_lxd_instances() {
    ensure_lxd_internal_ipv4
    command -v lxc >/dev/null 2>&1 || return 0

    local names
    names=$(list_lxd_instances)
    [ -z "$names" ] && return 0

    warn "检测到 LXD 里已经存在实例："
    echo "$names" | sed 's/^/  - /'
    warn "如果这是重新安装面板，面板数据库可能为空，但 LXD 里残留实例会导致创建同名服务器时报“容器已存在”。"
    reading "是否删除这些 LXD 实例？这会删除对应服务器数据，默认不删除 (y/n) [n]：" cleanup_confirm
    cleanup_confirm=${cleanup_confirm:-n}

    if [[ "$cleanup_confirm" =~ ^[yY]$ ]]; then
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            warn "删除 LXD 实例: $name"
            lxc delete -f "$name" || err "删除 LXD 实例失败: $name"
        done << EOF
$names
EOF
        ok "已清理 LXD 残留实例"
    else
        warn "已保留现有 LXD 实例。请创建服务器时避开同名，或手动执行 lxc delete -f 名称。"
    fi
}

disable_lxdapi_acme() {
    [ -f "$CONFIG_FILE" ] || return 0

    local tmp_file
    tmp_file=$(mktemp)
    awk '
        /^  acme:/ { in_acme=1; print; next }
        in_acme && /^  [^[:space:]]/ { in_acme=0 }
        in_acme && /^[[:space:]]*enabled:[[:space:]]*/ {
            sub(/enabled:[[:space:]]*.*/, "enabled: false")
        }
        { print }
    ' "$CONFIG_FILE" > "$tmp_file" || err "生成新配置失败"

    mv "$tmp_file" "$CONFIG_FILE" || err "写入配置失败"
    pkill -f "acme.sh --issue" >/dev/null 2>&1 || true
    ok "已关闭 ACME 插件，避免纯 IP 证书签发卡住服务"
}

get_lxdapi_port() {
    local port="8443"
    if [ -f "$CONFIG_FILE" ]; then
        local parsed
        parsed=$(awk '
            /^server:/ { in_server=1; next }
            in_server && /^[^[:space:]]/ { in_server=0 }
            in_server && /^[[:space:]]*port:/ {
                gsub(/[^0-9]/, "", $0)
                print $0
                exit
            }
        ' "$CONFIG_FILE")
        [ -n "$parsed" ] && port="$parsed"
    fi
    echo "$port"
}

restart_lxdapi_after_install() {
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
        warn "未找到 ${SERVICE_NAME}.service，跳过服务重启"
        return 0
    fi

    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME" || err "重启 $SERVICE_NAME 失败"
    sleep 3

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "$SERVICE_NAME 已重启并运行"
    else
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        err "$SERVICE_NAME 未正常运行"
    fi

    local port
    port=$(get_lxdapi_port)
    local curl_bin
    curl_bin=$(find_bin curl || true)
    if [ -n "$curl_bin" ]; then
        if "$curl_bin" -k -m 8 -fsS "https://127.0.0.1:${port}/admin/login" >/dev/null 2>&1; then
            ok "面板本地 HTTPS 检测通过: https://127.0.0.1:${port}/admin/login"
        else
            warn "面板本地 HTTPS 检测未通过，请查看 journalctl -u lxdapi -n 80 --no-pager"
        fi
    fi
}

post_panel_install_fix() {
    info "执行安装后修复：lxc 路径、LXD 内网 IPv4、ACME、服务状态..."
    ensure_lxd_internal_ipv4
    disable_lxdapi_acme
    restart_lxdapi_after_install
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
    echo "0. 退出"
    echo
}

run_full_install() {
    run_remote_script "lxd_install.sh" || err "LXD 安装失败"
    offer_cleanup_existing_lxd_instances
    run_remote_script "lxdapi_install.sh" || err "面板安装失败"
    post_panel_install_fix
    run_remote_script "image_import.sh" || err "镜像导入脚本执行失败"
    ok "一键完整安装流程执行完成"
    print_urls
}

install_lxd_only() {
    run_remote_script "lxd_install.sh" || err "LXD 安装失败"
    ensure_lxd_internal_ipv4
    offer_cleanup_existing_lxd_instances
}

install_panel_only() {
    run_remote_script "lxdapi_install.sh" || err "面板安装失败"
    post_panel_install_fix
    print_urls
}

import_images_only() {
    run_remote_script "image_import.sh" || err "镜像导入脚本执行失败"
}

update_panel_only() {
    run_remote_script "lxdapi_update.sh" || err "面板更新失败"
    post_panel_install_fix
    print_urls
}

uninstall_panel_only() {
    warn "卸载只会删除 Sakura/LXDAPI 面板，不会删除 LXD、镜像和已创建的服务器。"
    run_remote_script "lxdapi_uninstall.sh" || err "面板卸载失败"
}

print_urls() {
    echo
    info "后台登录地址: https://服务器IP:8443/admin/login"
    info "WHMCS API: https://服务器IP:8443/api/system/containers"
}

run_choice() {
    local choice="$1"
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
        run_choice "$1"
        exit 0
    fi

    show_menu
    reading "请选择 [1-6]，默认一键完整安装 [1]：" choice
    choice=${choice:-1}
    run_choice "$choice"
}

main "$@"
