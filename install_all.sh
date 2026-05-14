#!/usr/bin/env bash
set -euo pipefail

REPO="lovejapan1/lxdapi_install"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SERVICE_NAME="lxdapi"
CONFIG_FILE="/opt/lxdapi/configs/config.yaml"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERR]${NC} $1"; }

run_remote_script() {
    local script_name="$1"
    local tmp_file="/tmp/${script_name}"

    info "下载 ${script_name}..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${BASE_URL}/${script_name}" -o "${tmp_file}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${tmp_file}" "${BASE_URL}/${script_name}"
    else
        err "未找到 curl 或 wget，请先安装 curl"
        exit 1
    fi

    chmod +x "${tmp_file}"
    bash "${tmp_file}"
}

ensure_lxc_path() {
    if command -v lxc >/dev/null 2>&1; then
        return 0
    fi

    if [ -x /snap/bin/lxc ]; then
        info "修复 lxc 命令路径..."
        mkdir -p /usr/local/bin
        ln -sf /snap/bin/lxc /usr/local/bin/lxc
        export PATH="/usr/local/bin:/snap/bin:${PATH}"
    fi
}

ensure_port_forwarding_runtime() {
    info "检查端口转发运行环境..."

    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 procps nftables iptables >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y iproute procps-ng nftables iptables >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iproute procps-ng nftables iptables >/dev/null 2>&1 || true
    fi

    modprobe nf_tables >/dev/null 2>&1 || true
    modprobe br_netfilter >/dev/null 2>&1 || true

    mkdir -p /etc/sysctl.d
    cat >/etc/sysctl.d/99-sakura-lxdapi-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now nftables >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -i lo -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT 1 -i lo -j ACCEPT >/dev/null 2>&1 || true
        iptables -C OUTPUT -o lo -j ACCEPT >/dev/null 2>&1 || iptables -I OUTPUT 1 -o lo -j ACCEPT >/dev/null 2>&1 || true
        iptables -C INPUT -p tcp --dport 8443 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT 1 -p tcp --dport 8443 -j ACCEPT >/dev/null 2>&1 || true
        iptables -C FORWARD -j ACCEPT >/dev/null 2>&1 || iptables -I FORWARD 1 -j ACCEPT >/dev/null 2>&1 || true
    fi

    ok "端口转发运行环境已处理"
}

ensure_lxd_internal_ipv4() {
    ensure_lxc_path

    if ! command -v lxc >/dev/null 2>&1; then
        warn "未检测到 lxc，跳过 LXD 网桥检查"
        return 0
    fi

    info "检查 LXD 内网 IPv4 与默认网卡配置..."

    if ! lxc network show lxdbr0 >/dev/null 2>&1; then
        info "创建 lxdbr0 网桥..."
        lxc network create lxdbr0 ipv4.address=auto ipv4.dhcp=true ipv4.nat=true ipv6.address=none >/dev/null 2>&1 || true
    fi

    local ipv4_addr=""
    ipv4_addr="$(lxc network get lxdbr0 ipv4.address 2>/dev/null || true)"
    if [ -z "${ipv4_addr}" ] || [ "${ipv4_addr}" = "none" ]; then
        info "为 lxdbr0 开启内网 IPv4..."
        lxc network set lxdbr0 ipv4.address auto >/dev/null 2>&1 || \
            lxc network set lxdbr0 ipv4.address 10.10.10.1/24 >/dev/null 2>&1 || true
    fi

    lxc network set lxdbr0 ipv4.dhcp true >/dev/null 2>&1 || true
    lxc network set lxdbr0 ipv4.nat true >/dev/null 2>&1 || true

    if ! lxc profile device show default 2>/dev/null | grep -q '^eth0:'; then
        lxc profile device add default eth0 nic nictype=bridged parent=lxdbr0 name=eth0 >/dev/null 2>&1 || true
    else
        lxc profile device set default eth0 nictype bridged >/dev/null 2>&1 || true
        lxc profile device set default eth0 parent lxdbr0 >/dev/null 2>&1 || true
        lxc profile device set default eth0 name eth0 >/dev/null 2>&1 || true
    fi

    if lxc storage show default >/dev/null 2>&1; then
        if ! lxc profile device show default 2>/dev/null | grep -q '^root:'; then
            lxc profile device add default root disk path=/ pool=default >/dev/null 2>&1 || true
        fi
    fi

    ok "LXD 内网 IPv4 已处理"
}

patch_panel_binary_words() {
    if [ ! -d /opt/lxdapi ]; then
        return 0
    fi

    local bins=""
    bins="$(find /opt/lxdapi -maxdepth 1 -type f -name 'lxdapi-*' 2>/dev/null || true)"
    if [ -z "${bins}" ]; then
        return 0
    fi

    if ! command -v perl >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y perl >/dev/null 2>&1 || true
        fi
    fi

    if ! command -v perl >/dev/null 2>&1; then
        warn "未找到 perl，跳过面板残留文字修复"
        return 0
    fi

    info "修复面板残留文字..."
    while IFS= read -r bin; do
        [ -n "${bin}" ] || continue
        local backup="${bin}.bak_words"
        cp -a "${bin}" "${backup}" 2>/dev/null || true
        if perl -0pi -e 's/容器端口/服务端口/g; s/容器列表/服务列表/g; s/容器管理/服务管理/g; s/容器名称/服务名称/g; s/容器密码/服务密码/g; s/容器信息/服务信息/g; s/容器状态/服务状态/g; s/容器类型/服务类型/g; s/容器IP/服务IP/g; s/添加容器/添加服务/g; s/创建容器/创建服务/g; s/删除容器/删除服务/g; s/暂无容器/暂无服务/g;' "${bin}" 2>/dev/null; then
            rm -f "${backup}" 2>/dev/null || true
        else
            cp -a "${backup}" "${bin}" 2>/dev/null || true
            rm -f "${backup}" 2>/dev/null || true
        fi
        chmod +x "${bin}" 2>/dev/null || true
    done <<< "${bins}"
    ok "面板残留文字已处理"
}

cleanup_unused_runtime_files() {
    info "清理安装缓存和临时备份..."
    rm -f /opt/lxdapi/lxdapi-*.bak_words 2>/dev/null || true
    rm -f /tmp/lxd_install.sh /tmp/lxdapi_install.sh /tmp/lxdapi_update.sh /tmp/image_import.sh /tmp/lxdapi_uninstall.sh 2>/dev/null || true

    if command -v apt-get >/dev/null 2>&1; then
        apt-get clean >/dev/null 2>&1 || true
    fi

    if [ -d /var/lib/snapd/cache ]; then
        find /var/lib/snapd/cache -type f -delete 2>/dev/null || true
    fi
    ok "无用缓存已清理"
}

disable_lxdapi_acme() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        warn "未找到 ${CONFIG_FILE}，跳过 ACME 配置修复"
        return 0
    fi

    info "关闭面板内置 ACME，避免 IP 证书签发阻塞服务..."
    cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    awk '
        BEGIN { in_acme=0 }
        /^[[:space:]]*acme:[[:space:]]*$/ { in_acme=1; print; next }
        in_acme && /^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$/ { sub(/true/, "false"); in_acme=0; print; next }
        in_acme && /^[^[:space:]]/ { in_acme=0 }
        { print }
    ' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"

    pkill -f "acme.sh --issue" 2>/dev/null || true
    ok "ACME 已关闭"
}

restart_lxdapi_after_install() {
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
        warn "未找到 ${SERVICE_NAME}.service，跳过服务重启检查"
        return 0
    fi

    info "重启 ${SERVICE_NAME} 服务..."
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "${SERVICE_NAME}" || true
    sleep 3

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "${SERVICE_NAME} 服务已运行"
    else
        warn "${SERVICE_NAME} 服务未正常运行，请查看: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
        return 0
    fi

    local port="8443"
    if [ -f "${CONFIG_FILE}" ]; then
        port="$(awk -F': *' '/^[[:space:]]*port:[[:space:]]*/ {print $2; exit}' "${CONFIG_FILE}" 2>/dev/null || true)"
        [ -n "${port}" ] || port="8443"
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl -k -m 8 -fsS "https://127.0.0.1:${port}/admin/login" >/dev/null 2>&1; then
            ok "面板本机访问正常: https://127.0.0.1:${port}/admin/login"
        else
            warn "面板本机访问未通过，请检查防火墙和日志"
        fi
    fi
}

post_panel_install_fix() {
    ensure_lxc_path
    ensure_port_forwarding_runtime
    ensure_lxd_internal_ipv4
    patch_panel_binary_words
    cleanup_unused_runtime_files
    disable_lxdapi_acme
    restart_lxdapi_after_install
}

offer_cleanup_existing_lxd_instances() {
    ensure_lxc_path

    if ! command -v lxc >/dev/null 2>&1; then
        return 0
    fi

    local names=""
    names="$(lxc list --format csv -c n 2>/dev/null || true)"
    if [ -z "${names}" ]; then
        ok "当前 LXD 没有残留服务器实例"
        return 0
    fi

    warn "检测到 LXD 中已有实例，这可能导致面板或 WHMCS 创建同名服务器失败:"
    echo "${names}"
    echo
    read -rp "是否删除这些残留 LXD 实例？仅影响 LXD 实例，不删除面板程序。(y/n) [n]: " cleanup
    cleanup="${cleanup:-n}"
    if [[ "${cleanup}" =~ ^[Yy]$ ]]; then
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            info "删除残留实例: ${name}"
            lxc delete -f "${name}" >/dev/null 2>&1 || warn "删除失败: ${name}"
        done <<< "${names}"
        ok "残留 LXD 实例清理完成"
    else
        warn "已保留现有 LXD 实例；如果创建同名服务器仍失败，请先删除或换名"
    fi
}

install_lxd_only() {
    run_remote_script "lxd_install.sh"
    ensure_port_forwarding_runtime
    ensure_lxd_internal_ipv4
    cleanup_unused_runtime_files
    offer_cleanup_existing_lxd_instances
}

install_panel_only() {
    run_remote_script "lxdapi_install.sh"
    post_panel_install_fix
}

import_images_only() {
    run_remote_script "image_import.sh"
}

update_panel_only() {
    run_remote_script "lxdapi_update.sh"
    post_panel_install_fix
}

uninstall_panel_only() {
    run_remote_script "lxdapi_uninstall.sh"
}

run_full_install() {
    install_lxd_only
    install_panel_only
    import_images_only
    cleanup_unused_runtime_files
}

show_header() {
    clear 2>/dev/null || true
    echo "========================================"
    echo "        Sakura LXDAPI 一键脚本"
    echo "        by Github-lovejapan1"
    echo "========================================"
    echo
}

show_menu() {
    echo "请选择操作："
    echo "  1. 完整安装（安装 LXD + 安装面板 + 导入镜像）"
    echo "  2. 仅安装 LXD"
    echo "  3. 仅安装面板"
    echo "  4. 仅导入镜像"
    echo "  5. 更新面板"
    echo "  6. 卸载面板"
    echo "  0. 退出"
    echo
}

main() {
    local action="${1:-}"

    case "${action}" in
        install|all)
            run_full_install
            ;;
        lxd)
            install_lxd_only
            ;;
        panel)
            install_panel_only
            ;;
        images|image)
            import_images_only
            ;;
        update)
            update_panel_only
            ;;
        uninstall|remove)
            uninstall_panel_only
            ;;
        "")
            show_header
            show_menu
            read -rp "请输入选项 [1]: " choice
            choice="${choice:-1}"
            case "${choice}" in
                1) run_full_install ;;
                2) install_lxd_only ;;
                3) install_panel_only ;;
                4) import_images_only ;;
                5) update_panel_only ;;
                6) uninstall_panel_only ;;
                0) exit 0 ;;
                *) err "无效选项"; exit 1 ;;
            esac
            ;;
        *)
            echo "用法: bash install_all.sh [install|lxd|panel|images|update|uninstall]"
            exit 1
            ;;
    esac

    echo
    ok "操作完成"
    echo "后台登录地址: https://服务器IP:8443/admin/login"
}

main "$@"
