#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"
cd /root >/dev/null 2>&1 || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REGEX=("debian|astra" "ubuntu")
RELEASE=("Debian" "Ubuntu")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(lsb_release -sd 2>/dev/null)")
SYS="${CMD[0]}"
[[ -n $SYS ]] || exit 1

SYSTEM=""
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

if [[ "$SYSTEM" != "Debian" && "$SYSTEM" != "Ubuntu" ]]; then
    echo -e "${RED}[ERR]${NC} 此脚本仅支持 Debian 和 Ubuntu 系统"
    exit 1
fi

if [[ "$SYSTEM" == "Debian" ]]; then
    OS_VERSION=$(cat /etc/debian_version | cut -d. -f1)
elif [[ "$SYSTEM" == "Ubuntu" ]]; then
    OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d. -f1)
fi

RECOMMENDED=false
if [[ "$SYSTEM" == "Debian" && ("$OS_VERSION" == "12" || "$OS_VERSION" == "13") ]]; then
    RECOMMENDED=true
elif [[ "$SYSTEM" == "Ubuntu" && ("$OS_VERSION" == "24" || "$OS_VERSION" == "25") ]]; then
    RECOMMENDED=true
fi

log() { echo -e "$1"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; exit 1; }
reading() { read -rp "$(echo -e "${GREEN}$1${NC}")" "$2"; }

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

install_package() {
    local package_name="$1"
    if package_installed "$package_name"; then
        ok "$package_name 已安装"
        return 0
    fi

    info "安装 $package_name..."
    apt-get install -y "$package_name" >/dev/null 2>&1 || apt-get install -y "$package_name" --fix-missing >/dev/null 2>&1 || true
    if package_installed "$package_name"; then
        ok "$package_name 已安装"
    else
        warn "$package_name 安装失败"
    fi
}

get_available_space() {
    df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}'
}

ensure_apt_ready() {
    local need_update=false
    local package_name=""
    for package_name in curl wget ca-certificates nftables snapd; do
        package_installed "$package_name" || need_update=true
    done

    if [[ "$need_update" == "true" ]]; then
        info "更新软件包列表..."
        apt-get update >/dev/null 2>&1 || true
    else
        ok "基础组件已安装，跳过 apt update"
    fi
}

ensure_snap_lxd() {
    info "安装基础组件..."
    ensure_apt_ready
    for package_name in curl wget ca-certificates nftables snapd; do
        install_package "$package_name"
    done

    if ! command -v nft >/dev/null 2>&1; then
        err "nftables 安装失败，请检查网络或软件源"
    fi

    systemctl enable --now snapd.socket >/dev/null 2>&1 || true
    if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet snapd; then
        systemctl start snapd >/dev/null 2>&1 || true
    fi

    for _ in {1..20}; do
        command -v snap >/dev/null 2>&1 && break
        sleep 1
    done

    if ! command -v snap >/dev/null 2>&1; then
        err "snap 命令不可用，无法安装 LXD"
    fi

    snap set system refresh.retain=2 >/dev/null 2>&1 || true

    if ! snap list lxd >/dev/null 2>&1; then
        info "开始安装 LXD，这一步受 snap 下载速度影响，可能需要几分钟..."
        snap install lxd --channel=latest/stable || {
            warn "首次安装 LXD 失败，尝试修复 snap core 后重试..."
            snap remove lxd >/dev/null 2>&1 || true
            snap install core || true
            snap install lxd --channel=latest/stable || err "LXD 安装失败"
        }
    else
        ok "LXD 已安装，跳过 snap install"
    fi

    snap alias lxd.lxc lxc >/dev/null 2>&1 || true
    snap alias lxd.lxd lxd >/dev/null 2>&1 || true
    [ -x /snap/bin/lxc ] && ln -sf /snap/bin/lxc /usr/local/bin/lxc
    [ -x /snap/bin/lxd ] && ln -sf /snap/bin/lxd /usr/local/bin/lxd
    hash -r 2>/dev/null || true

    if systemctl list-unit-files 2>/dev/null | grep -q '^snap.lxd.daemon.service'; then
        systemctl enable --now snap.lxd.daemon.service >/dev/null 2>&1 || true
    fi

    if [ ! -f /etc/profile.d/snap.sh ]; then
        echo 'export PATH=$PATH:/snap/bin' > /etc/profile.d/snap.sh
    fi

    if dpkg -l lxcfs 2>/dev/null | grep -q "^ii"; then
        warn "检测到 deb 版 lxcfs，正在移除..."
        systemctl stop lxcfs >/dev/null 2>&1 || true
        systemctl disable lxcfs >/dev/null 2>&1 || true
        apt-get remove -y lxcfs >/dev/null 2>&1 || true
        ok "deb 版 lxcfs 已移除"
    fi

    snap set lxd lxcfs.flags="-l" >/dev/null 2>&1 || true
    snap set lxd daemon.debug=false >/dev/null 2>&1 || true

    if ! lxc list >/dev/null 2>&1; then
        snap restart lxd >/dev/null 2>&1 || true
        sleep 3
    fi

    lxd_version=$(lxd --version 2>/dev/null || true)
    info "LXD 版本: ${lxd_version:-unknown}"
    if [[ -n "$lxd_version" && ! "$lxd_version" =~ ^6\. ]]; then
        warn "当前 LXD 版本不是 6.x；如你的系统自动安装 5.x，通常也能运行 Sakura 面板"
    fi
}

init_lxd() {
    if lxc list >/dev/null 2>&1; then
        ok "LXD 已初始化"
        return 0
    fi

    info "初始化 LXD..."
    if [ -x /snap/bin/lxd ]; then
        /snap/bin/lxd init --auto >/dev/null 2>&1 || true
    else
        lxd init --auto >/dev/null 2>&1 || true
    fi

    for _ in {1..20}; do
        lxc list >/dev/null 2>&1 && { ok "LXD 初始化完成"; return 0; }
        sleep 1
    done

    err "LXD 初始化失败，请先确认 lxc list 可以正常执行"
}

init_lxd_network() {
    if ! lxc network show lxdbr0 >/dev/null 2>&1; then
        info "创建默认网络 lxdbr0..."
        lxc network create lxdbr0 >/dev/null 2>&1 || err "创建 lxdbr0 失败"
        ok "网络 lxdbr0 创建成功"
    else
        ok "网络 lxdbr0 已存在"
    fi

    if ! lxc profile device show default 2>/dev/null | grep -q "eth0"; then
        info "配置 default profile 网络设备..."
        lxc profile device add default eth0 nic network=lxdbr0 name=eth0 >/dev/null 2>&1 || true
        ok "网络设备已添加到 default profile"
    fi

    reading "是否开启 IPv4 DHCP/NAT？(y/n) [y]：" ipv4_dhcp
    ipv4_dhcp=${ipv4_dhcp:-y}
    if [[ "$ipv4_dhcp" =~ ^[yY]$ ]]; then
        lxc network set lxdbr0 ipv4.dhcp true >/dev/null 2>&1 || true
        lxc network set lxdbr0 ipv4.nat true >/dev/null 2>&1 || true
        ok "IPv4 DHCP 与 NAT 已开启"
    else
        lxc network set lxdbr0 ipv4.dhcp false >/dev/null 2>&1 || true
        ok "IPv4 DHCP 已关闭"
    fi

    reading "是否开启 IPv6 DHCP/NAT？(y/n) [y]：" ipv6_dhcp
    ipv6_dhcp=${ipv6_dhcp:-y}
    if [[ "$ipv6_dhcp" =~ ^[yY]$ ]]; then
        lxc network set lxdbr0 ipv6.dhcp true >/dev/null 2>&1 || true
        lxc network set lxdbr0 ipv6.nat true >/dev/null 2>&1 || true
        ok "IPv6 DHCP 与 NAT 已开启"
    else
        lxc network set lxdbr0 ipv6.dhcp false >/dev/null 2>&1 || true
        lxc network set lxdbr0 ipv6.address none >/dev/null 2>&1 || true
        ok "IPv6 DHCP 已关闭"
    fi
}

setup_storage() {
    info "配置存储池..."

    if lxc storage show default >/dev/null 2>&1; then
        ok "存储池 default 已存在"
        lxc storage list
        return 0
    fi

    available_space=$(get_available_space)
    info "当前可用磁盘空间: ${available_space}GB"

    while true; do
        reading "请选择存储后端 zfs/btrfs/lvm/dir [zfs]：" storage_driver
        storage_driver=${storage_driver:-zfs}
        if [[ "$storage_driver" =~ ^(zfs|btrfs|lvm|dir)$ ]]; then
            break
        fi
        warn "请输入 zfs、btrfs、lvm 或 dir"
    done

    case "$storage_driver" in
        zfs)
            if ! command -v zpool >/dev/null 2>&1; then
                info "安装 ZFS..."
                if [[ "$SYSTEM" == "Ubuntu" ]]; then
                    install_package zfsutils-linux
                else
                    bash <(curl -sL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/debian_zfs.sh)
                fi
            fi
            snap set lxd zfs.external=true >/dev/null 2>&1 || true
            snap restart lxd >/dev/null 2>&1 || true
            sleep 3
            ;;
        btrfs)
            install_package btrfs-progs
            ;;
        lvm)
            install_package lvm2
            ;;
    esac

    if [[ "$storage_driver" == "dir" ]]; then
        lxc storage create default dir >/dev/null 2>&1 || err "存储池创建失败"
    else
        reading "请输入存储池大小(GB) [${available_space}]：" pool_size
        pool_size=${pool_size:-$available_space}
        lxc storage create default "$storage_driver" size="${pool_size}GB" >/dev/null 2>&1 || err "存储池创建失败"
    fi

    ok "存储池 default 创建成功"
    if ! lxc profile device show default 2>/dev/null | grep -q "root"; then
        lxc profile device add default root disk path=/ pool=default >/dev/null 2>&1 || true
        ok "存储池已添加到 default profile"
    fi
}

main() {
    echo
    echo "========================================"
    echo "        LXD 安装脚本"
    echo "        by Sakura"
    echo "========================================"
    echo

    info "系统: $SYSTEM $OS_VERSION"
    if [[ "$RECOMMENDED" == "true" ]]; then
        ok "系统版本符合推荐"
    else
        warn "推荐使用 Debian 12/13 或 Ubuntu 24/25，当前系统也会尝试安装"
        reading "是否继续？(y/n) [y]：" confirm_install
        confirm_install=${confirm_install:-y}
        [[ "$confirm_install" =~ ^[yY]$ ]] || err "安装已取消"
    fi

    echo
    echo "======== 步骤 1/4: 安装 LXD ========"
    reading "是否安装 LXD？(y/n) [y]：" step1_confirm
    step1_confirm=${step1_confirm:-y}
    if [[ "$step1_confirm" =~ ^[yY]$ ]]; then
        ensure_snap_lxd
        init_lxd
        ok "LXD 安装完成"
    else
        warn "已跳过 LXD 安装"
    fi

    echo
    echo "======== 步骤 2/4: 网络配置 ========"
    reading "是否配置 LXD 网络？(y/n) [y]：" step2_confirm
    step2_confirm=${step2_confirm:-y}
    if [[ "$step2_confirm" =~ ^[yY]$ ]]; then
        init_lxd_network
        ok "网络配置完成"
    else
        warn "已跳过网络配置"
    fi

    echo
    echo "======== 步骤 3/4: 存储配置 ========"
    reading "是否配置 LXD 存储池？(y/n) [y]：" step3_confirm
    step3_confirm=${step3_confirm:-y}
    if [[ "$step3_confirm" =~ ^[yY]$ ]]; then
        setup_storage
        ok "存储配置完成"
    else
        warn "已跳过存储配置"
    fi

    echo
    echo "======== 步骤 4/4: 完成 ========"
    ok "LXD 安装配置完成"
    echo
    info "===== 网络配置 ====="
    lxc network list 2>/dev/null || true
    echo
    info "===== 存储配置 ====="
    lxc storage list 2>/dev/null || true
}

main "$@"
