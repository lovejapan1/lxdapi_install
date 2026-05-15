#!/usr/bin/env bash
set -euo pipefail

REPO="lovejapan1/lxdapi_install"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SERVICE_NAME="lxdapi"
INSTALL_DIR="/opt/lxdapi"
CONFIG_FILE="${INSTALL_DIR}/configs/config.yaml"
DB_FILE="${INSTALL_DIR}/lxdapi.db"

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

lxc_cmd() {
    if command -v lxc >/dev/null 2>&1; then
        command lxc "$@"
    elif [ -x /snap/bin/lxc ]; then
        /snap/bin/lxc "$@"
    else
        return 127
    fi
}

ensure_lxc_path() {
    if command -v lxc >/dev/null 2>&1; then
        return 0
    fi
    if [ -x /snap/bin/lxc ]; then
        mkdir -p /usr/local/bin
        ln -sf /snap/bin/lxc /usr/local/bin/lxc
        export PATH="/usr/local/bin:/snap/bin:${PATH}"
    fi
}

detect_public_interface() {
    local route_line=""
    local route_if=""
    local src_ip=""
    local src_if=""
    local default_if=""
    local global_if=""

    route_line="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
    route_if="$(echo "${route_line}" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    src_ip="$(echo "${route_line}" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"

    if [ -n "${src_ip}" ]; then
        src_if="$(ip -o -4 addr show scope global 2>/dev/null | awk -v ip="${src_ip}" '{split($4,a,"/"); if(a[1]==ip){print $2; exit}}')"
        if [ -n "${src_if}" ] && ip link show "${src_if}" >/dev/null 2>&1; then
            echo "${src_if}"
            return 0
        fi
    fi

    if [ -n "${route_if}" ] && ip link show "${route_if}" >/dev/null 2>&1; then
        echo "${route_if}"
        return 0
    fi

    default_if="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [ -n "${default_if}" ] && ip link show "${default_if}" >/dev/null 2>&1; then
        echo "${default_if}"
        return 0
    fi

    global_if="$(ip -o -4 addr show scope global 2>/dev/null | awk '$2!="lo" {print $2; exit}')"
    echo "${global_if}"
}

detect_bind_ipv4() {
    local iface="$1"
    local ip_addr=""
    if [ -n "${iface}" ]; then
        ip_addr="$(ip -o -4 addr show dev "${iface}" scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4; exit}')"
    fi
    if [ -z "${ip_addr}" ]; then
        ip_addr="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    fi
    echo "${ip_addr}"
}

detect_display_ipv4() {
    local fallback_ip="$1"
    local public_ip=""
    if command -v curl >/dev/null 2>&1; then
        public_ip="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
    fi
    [ -n "${public_ip}" ] || public_ip="${fallback_ip}"
    echo "${public_ip}"
}

detect_lxd_cidr() {
    local cidr=""
    cidr="$(ip -o -4 route show dev lxdbr0 scope link 2>/dev/null | awk '{print $1; exit}')"
    [ -n "${cidr}" ] || cidr="$(ip -o -4 addr show lxdbr0 2>/dev/null | awk '{print $4; exit}')"
    echo "${cidr}"
}

ensure_forwarding_sysctl() {
    mkdir -p /etc/sysctl.d
    cat >/etc/sysctl.d/99-sakura-lxdapi-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
}

remove_manual_masquerade_rules() {
    local lxd_cidr="$1"
    local ipt=""
    local rule=""
    local delete_rule=""

    [ -n "${lxd_cidr}" ] || return 0
    for ipt in iptables iptables-legacy; do
        command -v "${ipt}" >/dev/null 2>&1 || continue
        while IFS= read -r rule; do
            [[ "${rule}" == *"-s ${lxd_cidr}"* ]] || continue
            [[ "${rule}" == *"-j MASQUERADE"* ]] || continue
            delete_rule="${rule/-A POSTROUTING/-D POSTROUTING}"
            read -r -a delete_args <<< "${delete_rule}"
            "${ipt}" -t nat "${delete_args[@]}" >/dev/null 2>&1 || true
        done < <("${ipt}" -t nat -S POSTROUTING 2>/dev/null || true)
    done
}

ensure_lxd_native_network() {
    ensure_lxc_path
    ensure_forwarding_sysctl

    if ! lxc_cmd list >/dev/null 2>&1; then
        warn "lxc 暂不可用，跳过 LXD 网络修复"
        return 0
    fi

    if ! lxc_cmd network show lxdbr0 >/dev/null 2>&1; then
        info "按原版逻辑创建 lxdbr0..."
        lxc_cmd network create lxdbr0 >/dev/null 2>&1 || true
    fi

    lxc_cmd network set lxdbr0 ipv4.dhcp true >/dev/null 2>&1 || true
    lxc_cmd network set lxdbr0 ipv4.nat true >/dev/null 2>&1 || true

    if ! lxc_cmd profile device show default 2>/dev/null | grep -q '^eth0:'; then
        lxc_cmd profile device add default eth0 nic network=lxdbr0 name=eth0 >/dev/null 2>&1 || true
    else
        lxc_cmd profile device set default eth0 network lxdbr0 >/dev/null 2>&1 || true
        lxc_cmd profile device set default eth0 name eth0 >/dev/null 2>&1 || true
    fi

    if lxc_cmd storage show default >/dev/null 2>&1; then
        if ! lxc_cmd profile device show default 2>/dev/null | grep -q '^root:'; then
            lxc_cmd profile device add default root disk path=/ pool=default >/dev/null 2>&1 || true
        fi
    fi

    ok "LXD 原生 NAT 已开启"
}

write_detected_nat_info() {
    local public_if="$1"
    local bind_ip="$2"
    local display_ip="$3"
    local lxd_cidr="$4"

    mkdir -p "${INSTALL_DIR}/configs" 2>/dev/null || true
    cat >"${INSTALL_DIR}/configs/auto_nat.env" <<EOF
PUBLIC_INTERFACE=${public_if}
BIND_IPV4=${bind_ip}
DISPLAY_IPV4=${display_ip}
LXD_CIDR=${lxd_cidr}
EOF
}

sync_lxdapi_panel_nat_config() {
    local public_if=""
    local bind_ip=""
    local display_ip=""
    local lxd_cidr=""
    local table=""
    local columns=""
    local key_col=""
    local value_col=""
    local col=""
    local count="0"
    local current=""
    local merged=""
    local escaped=""
    local sql=""

    public_if="$(detect_public_interface)"
    bind_ip="$(detect_bind_ipv4 "${public_if}")"
    display_ip="$(detect_display_ipv4 "${bind_ip}")"
    lxd_cidr="$(detect_lxd_cidr)"

    [ -n "${public_if}" ] || { warn "未检测到公网出口网卡"; return 0; }
    [ -n "${bind_ip}" ] || bind_ip="${display_ip}"
    [ -n "${display_ip}" ] || display_ip="${bind_ip}"

    info "自动识别公网网卡: ${public_if}"
    info "自动识别绑定 IPv4: ${bind_ip}"
    info "自动识别显示 IPv4: ${display_ip}"
    [ -n "${lxd_cidr}" ] && info "自动识别 LXD 网段: ${lxd_cidr}"

    write_detected_nat_info "${public_if}" "${bind_ip}" "${display_ip}" "${lxd_cidr}"
    remove_manual_masquerade_rules "${lxd_cidr}"

    [ -f "${DB_FILE}" ] || return 0

    if ! command -v sqlite3 >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3 >/dev/null 2>&1 || true
        fi
    fi
    if ! command -v perl >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y perl >/dev/null 2>&1 || true
        fi
    fi
    command -v sqlite3 >/dev/null 2>&1 || { warn "未找到 sqlite3，跳过面板 NAT 自动同步"; return 0; }
    command -v perl >/dev/null 2>&1 || { warn "未找到 perl，跳过面板 NAT 自动同步"; return 0; }

    cp -a "${DB_FILE}" "${DB_FILE}.bak_nat.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    for table in system_configs configs settings; do
        sqlite3 "${DB_FILE}" "SELECT name FROM sqlite_master WHERE type='table' AND name='${table}';" 2>/dev/null | grep -qx "${table}" || continue
        columns="$(sqlite3 "${DB_FILE}" "PRAGMA table_info(\"${table}\");" 2>/dev/null | awk -F'|' '{print $2}')"
        key_col=""
        value_col=""
        for col in key config_key name config_name; do
            echo "${columns}" | grep -qx "${col}" && { key_col="${col}"; break; }
        done
        for col in value config_value data content; do
            echo "${columns}" | grep -qx "${col}" && { value_col="${col}"; break; }
        done
        [ -n "${key_col}" ] || continue
        [ -n "${value_col}" ] || continue

        count="$(sqlite3 "${DB_FILE}" "SELECT COUNT(*) FROM \"${table}\" WHERE \"${key_col}\"='snat_config_v4';" 2>/dev/null || echo 0)"
        current="$(sqlite3 "${DB_FILE}" "SELECT \"${value_col}\" FROM \"${table}\" WHERE \"${key_col}\"='snat_config_v4' LIMIT 1;" 2>/dev/null || true)"
        merged="$(CURRENT_JSON="${current}" NAT_IF="${public_if}" NAT_IP="${bind_ip}" NAT_DISPLAY="${display_ip}" perl -MJSON::PP -e '
            my $json = $ENV{CURRENT_JSON} // "";
            my $arr = eval { decode_json($json) };
            $arr = [] unless ref($arr) eq "ARRAY";
            my $found = 0;
            for my $item (@$arr) {
                next unless ref($item) eq "HASH";
                my $iface = $item->{interface} // "";
                my $ip = $item->{ip} // "";
                my $display = $item->{display_ip} // "";
                if ($iface eq "eth0" || $ip eq $ENV{NAT_IP} || $display eq $ENV{NAT_DISPLAY}) {
                    $item->{interface} = $ENV{NAT_IF};
                    $item->{ip} = $ENV{NAT_IP};
                    $item->{display_ip} = $ENV{NAT_DISPLAY};
                    $item->{protocol} = "both" unless $item->{protocol};
                    $found = 1;
                }
            }
            if (!@$arr || !$found) {
                push @$arr, { interface => $ENV{NAT_IF}, ip => $ENV{NAT_IP}, display_ip => $ENV{NAT_DISPLAY}, protocol => "both" };
            }
            print encode_json($arr);
        ' 2>/dev/null || true)"
        [ -n "${merged}" ] || continue
        escaped="${merged//\'/\'\'}"

        if [ "${count}" = "0" ]; then
            sql="INSERT INTO \"${table}\" (\"${key_col}\", \"${value_col}\") VALUES ('snat_config_v4', '${escaped}');"
        else
            sql="UPDATE \"${table}\" SET \"${value_col}\"='${escaped}' WHERE \"${key_col}\"='snat_config_v4';"
        fi
        sqlite3 "${DB_FILE}" "${sql}" >/dev/null 2>&1 || true
        ok "面板 IPv4 NAT 配置已自动同步"
        return 0
    done

    warn "未找到面板 NAT 配置表，只写入 auto_nat.env"
}

patch_panel_binary_words() {
    [ -d "${INSTALL_DIR}" ] || return 0
    local bins=""
    bins="$(find "${INSTALL_DIR}" -maxdepth 1 -type f -name 'lxdapi-*' 2>/dev/null || true)"
    [ -n "${bins}" ] || return 0

    if ! command -v perl >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y perl >/dev/null 2>&1 || true
        fi
    fi
    command -v perl >/dev/null 2>&1 || return 0

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
}

disable_lxdapi_acme() {
    [ -f "${CONFIG_FILE}" ] || return 0
    cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    awk '
        BEGIN { in_acme=0 }
        /^[[:space:]]*acme:[[:space:]]*$/ { in_acme=1; print; next }
        in_acme && /^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$/ { sub(/true/, "false"); in_acme=0; print; next }
        in_acme && /^[^[:space:]]/ { in_acme=0 }
        { print }
    ' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
    pkill -f "acme.sh --issue" 2>/dev/null || true
}

cleanup_unused_runtime_files() {
    rm -f /opt/lxdapi/lxdapi-*.bak_words 2>/dev/null || true
    rm -f /tmp/lxd_install.sh /tmp/lxdapi_install.sh /tmp/lxdapi_update.sh /tmp/image_import.sh /tmp/lxdapi_uninstall.sh 2>/dev/null || true
    command -v apt-get >/dev/null 2>&1 && apt-get clean >/dev/null 2>&1 || true
    [ -d /var/lib/snapd/cache ] && find /var/lib/snapd/cache -type f -delete 2>/dev/null || true
}

restart_lxdapi_after_install() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart "${SERVICE_NAME}" || true
        sleep 3
        systemctl is-active --quiet "${SERVICE_NAME}" && ok "${SERVICE_NAME} 服务已运行" || warn "${SERVICE_NAME} 服务未正常运行"
    fi
}

post_panel_install_fix() {
    ensure_lxc_path
    ensure_lxd_native_network
    sync_lxdapi_panel_nat_config
    patch_panel_binary_words
    cleanup_unused_runtime_files
    disable_lxdapi_acme
    restart_lxdapi_after_install
}

offer_cleanup_existing_lxd_instances() {
    ensure_lxc_path
    lxc_cmd list >/dev/null 2>&1 || return 0
    local names=""
    names="$(lxc_cmd list --format csv -c n 2>/dev/null || true)"
    [ -n "${names}" ] || { ok "当前 LXD 没有残留服务器实例"; return 0; }

    warn "检测到 LXD 中已有实例，可能导致 WHMCS 创建同名服务器失败:"
    echo "${names}"
    read -rp "是否删除这些残留 LXD 实例？(y/n) [n]: " cleanup
    cleanup="${cleanup:-n}"
    if [[ "${cleanup}" =~ ^[Yy]$ ]]; then
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            lxc_cmd delete -f "${name}" >/dev/null 2>&1 || warn "删除失败: ${name}"
        done <<< "${names}"
    fi
}

install_lxd_only() {
    run_remote_script "lxd_install.sh"
    ensure_lxd_native_network
    sync_lxdapi_panel_nat_config
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
        install|all) run_full_install ;;
        lxd) install_lxd_only ;;
        panel) install_panel_only ;;
        images|image) import_images_only ;;
        update) update_panel_only ;;
        uninstall|remove) uninstall_panel_only ;;
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
