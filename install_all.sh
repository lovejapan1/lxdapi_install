#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

REPO="lovejapan1/lxdapi_install"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
INSTALL_DIR="/opt/lxdapi"
CONFIG_FILE="${INSTALL_DIR}/configs/config.yaml"

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
    if ! command -v lxc >/dev/null 2>&1 && [ -x /snap/bin/lxc ]; then
        mkdir -p /usr/local/bin
        ln -sf /snap/bin/lxc /usr/local/bin/lxc
    fi
}

detect_public_interface() {
    local route_line route_if src_ip src_if
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

    ip -o -4 addr show scope global 2>/dev/null | awk '$2!="lo" {print $2; exit}'
}

detect_bind_ipv4() {
    local iface="$1"
    local ip_addr=""
    if [ -n "${iface}" ]; then
        ip_addr="$(ip -o -4 addr show dev "${iface}" scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4; exit}')"
    fi
    [ -n "${ip_addr}" ] || ip_addr="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    echo "${ip_addr}"
}

detect_lxd_cidr() {
    local cidr=""
    cidr="$(ip -o -4 route show dev lxdbr0 scope link 2>/dev/null | awk '{print $1; exit}')"
    [ -n "${cidr}" ] || cidr="$(ip -o -4 addr show lxdbr0 2>/dev/null | awk '{print $4; exit}')"
    echo "${cidr}"
}

write_auto_nat_env() {
    local iface="$1"
    local ip="$2"
    local cidr="$3"
    mkdir -p "${INSTALL_DIR}/configs"
    cat >"${INSTALL_DIR}/configs/auto_nat.env" <<EOF
PUBLIC_INTERFACE=${iface}
BIND_IPV4=${ip}
DISPLAY_IPV4=${ip}
LXD_CIDR=${cidr}
EOF
}

install_repair_service() {
    command -v systemctl >/dev/null 2>&1 || return 0
    mkdir -p /usr/local/sbin
    cat >/usr/local/sbin/sakura-lxdapi-repair.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

CONFIG_FILE="/opt/lxdapi/configs/auto_nat.env"
[ -f "${CONFIG_FILE}" ] && . "${CONFIG_FILE}" || true

lxc_cmd() {
    if command -v lxc >/dev/null 2>&1; then
        command lxc "$@"
    elif [ -x /snap/bin/lxc ]; then
        /snap/bin/lxc "$@"
    else
        return 127
    fi
}

detect_public_if() {
    local route_line route_if src_ip src_if
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
    ip -o -4 addr show scope global 2>/dev/null | awk '$2!="lo" {print $2; exit}'
}

detect_lxd_cidr() {
    local cidr=""
    cidr="$(ip -o -4 route show dev lxdbr0 scope link 2>/dev/null | awk '{print $1; exit}')"
    [ -n "${cidr}" ] || cidr="$(ip -o -4 addr show lxdbr0 2>/dev/null | awk '{print $4; exit}')"
    echo "${cidr}"
}

collect_ifaces() {
    local public_if="${PUBLIC_INTERFACE:-}"
    [ -n "${public_if}" ] && echo "${public_if}"
    public_if="$(detect_public_if)"
    [ -n "${public_if}" ] && echo "${public_if}"
    if command -v nft >/dev/null 2>&1; then
        nft list ruleset 2>/dev/null | awk '
            /dnat/ && /iifname/ {
                for (i=1; i<=NF; i++) {
                    if ($i=="iifname") {
                        gsub(/"/, "", $(i+1));
                        print $(i+1);
                    }
                }
            }
        '
    fi
}

add_forward_rule() {
    local ipt="$1"
    shift
    command -v "${ipt}" >/dev/null 2>&1 || return 0
    "${ipt}" -C FORWARD "$@" >/dev/null 2>&1 || "${ipt}" -I FORWARD 1 "$@" >/dev/null 2>&1 || true
}

add_masquerade_rule() {
    local iface="$1"
    local cidr="$2"
    local ipt=""

    for ipt in iptables iptables-legacy; do
        command -v "${ipt}" >/dev/null 2>&1 || continue
        "${ipt}" -t nat -C POSTROUTING -s "${cidr}" -o "${iface}" -j MASQUERADE >/dev/null 2>&1 || \
            "${ipt}" -t nat -I POSTROUTING 1 -s "${cidr}" -o "${iface}" -j MASQUERADE >/dev/null 2>&1 || true
    done

    command -v nft >/dev/null 2>&1 || return 0
    nft add table ip sakura_lxdapi_snat >/dev/null 2>&1 || true
    nft add chain ip sakura_lxdapi_snat postrouting '{ type nat hook postrouting priority 101; policy accept; }' >/dev/null 2>&1 || true
    if ! nft list chain ip sakura_lxdapi_snat postrouting 2>/dev/null | grep -Fq "ip saddr ${cidr} oifname \"${iface}\" masquerade"; then
        nft add rule ip sakura_lxdapi_snat postrouting ip saddr "${cidr}" oifname "${iface}" masquerade >/dev/null 2>&1 || true
    fi
}

mirror_dnat_rules() {
    command -v nft >/dev/null 2>&1 || return 0
    local lines=""
    lines="$(nft list ruleset 2>/dev/null | awk '
        /dnat ip to/ && /dport/ {
            pub=""; proto=""; port=""; target="";
            for (i=1; i<=NF; i++) {
                if ($i=="daddr") pub=$(i+1);
                if ($i=="tcp" || $i=="udp") proto=$i;
                if ($i=="dport") port=$(i+1);
                if ($i=="to") target=$(i+1);
            }
            if (pub && proto && port && target) print proto, pub, port, target;
        }
    ' | awk 'NF && !seen[$0]++')"
    [ -n "${lines}" ] || return 0

    nft delete table ip sakura_lxdapi_nat >/dev/null 2>&1 || true
    nft add table ip sakura_lxdapi_nat >/dev/null 2>&1 || return 0
    nft add chain ip sakura_lxdapi_nat prerouting '{ type nat hook prerouting priority -101; policy accept; }' >/dev/null 2>&1 || true

    while read -r proto pub port target; do
        [ -n "${proto}" ] && [ -n "${pub}" ] && [ -n "${port}" ] && [ -n "${target}" ] || continue
        nft add rule ip sakura_lxdapi_nat prerouting ip daddr "${pub}" "${proto}" dport "${port}" dnat to "${target}" >/dev/null 2>&1 || true
    done <<< "${lines}"
}

repair_container_ssh() {
    lxc_cmd list >/dev/null 2>&1 || return 0
    local name=""
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        lxc_cmd exec "${name}" -- sh -lc '
            command -v sshd >/dev/null 2>&1 || exit 0
            mkdir -p /run/sshd /var/run/sshd
            command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -A >/dev/null 2>&1 || true
            if [ -f /etc/ssh/sshd_config ]; then
                sed -i \
                    -e "s/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/" \
                    -e "s/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/" \
                    -e "s/^[#[:space:]]*UsePAM.*/UsePAM yes/" \
                    /etc/ssh/sshd_config 2>/dev/null || true
                grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
                grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
            fi
            if command -v rc-service >/dev/null 2>&1; then
                rc-update add sshd default >/dev/null 2>&1 || true
                rc-service sshd restart >/dev/null 2>&1 || rc-service sshd start >/dev/null 2>&1 || /usr/sbin/sshd >/dev/null 2>&1 || true
            elif command -v systemctl >/dev/null 2>&1; then
                systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || /usr/sbin/sshd >/dev/null 2>&1 || true
            elif command -v service >/dev/null 2>&1; then
                service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1 || /usr/sbin/sshd >/dev/null 2>&1 || true
            else
                /usr/sbin/sshd >/dev/null 2>&1 || true
            fi
        ' >/dev/null 2>&1 || true
    done < <(lxc_cmd list --format csv -c n 2>/dev/null || true)
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
cidr="${LXD_CIDR:-}"
[ -n "${cidr}" ] || cidr="$(detect_lxd_cidr)"

if [ -n "${cidr}" ]; then
    while IFS= read -r iface; do
        [ -n "${iface}" ] || continue
        [ "${iface}" = "lo" ] && continue
        [ "${iface}" = "lxdbr0" ] && continue
        ip link show "${iface}" >/dev/null 2>&1 || continue
        for ipt in iptables iptables-legacy; do
            add_forward_rule "${ipt}" -i "${iface}" -o lxdbr0 -d "${cidr}" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
            add_forward_rule "${ipt}" -i lxdbr0 -o "${iface}" -s "${cidr}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        done
        add_masquerade_rule "${iface}" "${cidr}"
    done < <(collect_ifaces | awk 'NF && !seen[$0]++')
fi

mirror_dnat_rules
repair_container_ssh
EOF

    chmod +x /usr/local/sbin/sakura-lxdapi-repair.sh

    cat >/etc/systemd/system/sakura-lxdapi-repair.service <<'EOF'
[Unit]
Description=Sakura LXDAPI NAT and SSH repair
After=network-online.target snap.lxd.daemon.service lxd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sakura-lxdapi-repair.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    cat >/etc/systemd/system/sakura-lxdapi-repair.timer <<'EOF'
[Unit]
Description=Run Sakura LXDAPI NAT and SSH repair

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
Unit=sakura-lxdapi-repair.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now sakura-lxdapi-repair.service >/dev/null 2>&1 || true
    systemctl enable --now sakura-lxdapi-repair.timer >/dev/null 2>&1 || true
}

ensure_lxd_network() {
    ensure_lxc_path
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    mkdir -p /etc/sysctl.d
    echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-sakura-lxdapi.conf

    if lxc_cmd list >/dev/null 2>&1; then
        if ! lxc_cmd network show lxdbr0 >/dev/null 2>&1; then
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
        if lxc_cmd storage show default >/dev/null 2>&1 && ! lxc_cmd profile device show default 2>/dev/null | grep -q '^root:'; then
            lxc_cmd profile device add default root disk path=/ pool=default >/dev/null 2>&1 || true
        fi
    fi

    local iface ip cidr
    iface="$(detect_public_interface)"
    ip="$(detect_bind_ipv4 "${iface}")"
    cidr="$(detect_lxd_cidr)"
    write_auto_nat_env "${iface}" "${ip}" "${cidr}"
    install_repair_service
    /usr/local/sbin/sakura-lxdapi-repair.sh >/dev/null 2>&1 || true
    ok "NAT/SSH 自动修复已安装"
}

patch_panel_words() {
    [ -d "${INSTALL_DIR}" ] || return 0
    command -v perl >/dev/null 2>&1 || return 0
    find "${INSTALL_DIR}" -maxdepth 1 -type f -name 'lxdapi-*' 2>/dev/null | while read -r bin; do
        [ -n "${bin}" ] || continue
        cp -a "${bin}" "${bin}.bak_words" 2>/dev/null || true
        if perl -0pi -e 's/容器端口/服务端口/g; s/容器列表/服务列表/g; s/容器管理/服务管理/g; s/容器名称/服务名称/g; s/容器密码/服务密码/g; s/容器信息/服务信息/g; s/容器状态/服务状态/g; s/容器类型/服务类型/g; s/容器IP/服务IP/g; s/添加容器/添加服务/g; s/创建容器/创建服务/g; s/删除容器/删除服务/g; s/暂无容器/暂无服务/g;' "${bin}" 2>/dev/null; then
            rm -f "${bin}.bak_words"
        else
            mv -f "${bin}.bak_words" "${bin}" 2>/dev/null || true
        fi
        chmod +x "${bin}" 2>/dev/null || true
    done
}

disable_acme() {
    [ -f "${CONFIG_FILE}" ] || return 0
    awk '
        BEGIN { in_acme=0 }
        /^[[:space:]]*acme:[[:space:]]*$/ { in_acme=1; print; next }
        in_acme && /^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$/ { sub(/true/, "false"); in_acme=0; print; next }
        in_acme && /^[^[:space:]]/ { in_acme=0 }
        { print }
    ' "${CONFIG_FILE}" >"${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
    pkill -f "acme.sh --issue" 2>/dev/null || true
}

restart_panel() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^lxdapi.service'; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart lxdapi >/dev/null 2>&1 || true
    fi
}

post_panel_fix() {
    ensure_lxd_network
    patch_panel_words
    disable_acme
    restart_panel
}

install_lxd_only() {
    run_remote_script "lxd_install.sh"
    ensure_lxd_network
}

install_panel_only() {
    run_remote_script "lxdapi_install.sh"
    post_panel_fix
}

import_images_only() {
    run_remote_script "image_import.sh"
}

update_panel_only() {
    run_remote_script "lxdapi_update.sh"
    post_panel_fix
}

uninstall_panel_only() {
    run_remote_script "lxdapi_uninstall.sh"
}

run_full_install() {
    install_lxd_only
    install_panel_only
    import_images_only
}

show_menu() {
    clear 2>/dev/null || true
    echo "========================================"
    echo "        Sakura LXDAPI 一键脚本"
    echo "        by Github-lovejapan1"
    echo "========================================"
    echo "1. 完整安装（LXD + 面板 + 镜像）"
    echo "2. 仅安装 LXD"
    echo "3. 仅安装面板"
    echo "4. 仅导入镜像"
    echo "5. 更新面板并修复 NAT/SSH"
    echo "6. 卸载面板"
    echo "0. 退出"
}

main() {
    case "${1:-}" in
        install|all) run_full_install ;;
        lxd) install_lxd_only ;;
        panel) install_panel_only ;;
        images|image) import_images_only ;;
        update) update_panel_only ;;
        fix|repair) post_panel_fix ;;
        uninstall|remove) uninstall_panel_only ;;
        "")
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
        *) echo "用法: bash install_all.sh [install|lxd|panel|images|update|fix|uninstall]"; exit 1 ;;
    esac

    echo
    ok "操作完成"
    echo "后台登录地址: https://服务器IP:8443/admin/login"
}

main "$@"
