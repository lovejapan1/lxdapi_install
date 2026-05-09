#!/bin/bash

cd /root >/dev/null 2>&1

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

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

if [[ "$SYSTEM" != "Debian" && "$SYSTEM" != "Ubuntu" ]]; then
    echo -e "${RED}[ERR]${NC} This script only supports Debian and Ubuntu"
    exit 1
fi

log() { echo -e "$1"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; exit 1; }

reading() { read -rp "$(echo -e "${GREEN}$1${NC}")" "$2"; }

install_package() {
    package_name=$1
    if dpkg -l 2>/dev/null | grep -q "^ii.*$package_name"; then
        ok "$package_name is installed"
    else
        apt-get install -y $package_name >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            apt-get install -y $package_name --fix-missing >/dev/null 2>&1
        fi
        if dpkg -l 2>/dev/null | grep -q "^ii.*$package_name"; then
            ok "$package_name is installed"
        else
            warn "$package_name install failed"
        fi
    fi
}

download_file() {
    url=$1
    output=$2
    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$output" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -LfsS --retry 3 -o "$output" "$url"
    else
        return 127
    fi
}

install_base_packages() {
    info "Updating package list..."
    apt-get update >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1

    info "Installing base packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y unzip e2fsprogs bc fdisk parted wget curl ca-certificates openssl tar >/dev/null 2>&1
    ok "Base packages installed"
}

deploy_lxdapi() {
    info "Checking system architecture..."
    sys_arch=$(uname -m)
    case $sys_arch in
        x86_64)
            arch="amd64"
            ok "Detected architecture: x86_64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ok "Detected architecture: $sys_arch"
            ;;
        *)
            err "Unsupported architecture: $sys_arch"
            ;;
    esac
    
    download_url="https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxdapi-linux-${arch}.tar.gz"
    
    info "Downloading lxdapi..."
    info "Download URL: $download_url"
    
    temp_file=$(mktemp)
    if download_file "$download_url" "$temp_file"; then
        ok "Download completed"
    else
        rm -f "$temp_file"
        err "Download failed: please install wget or curl"
    fi
    
    info "Extracting to /opt/lxdapi..."
    mkdir -p /opt/lxdapi
    tar -xzf "$temp_file" -C /opt/lxdapi --strip-components=1
    rm -f "$temp_file"
}

configure_lxdapi() {
    info "Configuring lxdapi..."
    
    config_file="/opt/lxdapi/configs/config.yaml"
    
    if [ ! -f "$config_file" ]; then
        err "Config file not found: $config_file"
    fi
    
    reading "Server port [8443]: " server_port
    server_port=${server_port:-8443}
    
    reading "API key [random]: " api_hash
    if [ -z "$api_hash" ]; then
        api_hash=$(openssl rand -hex 16)
        ok "API key generated: $api_hash"
    fi
    
    reading "Admin username [admin]: " admin_user
    admin_user=${admin_user:-admin}
    
    reading "Admin password [random]: " admin_pass
    if [ -z "$admin_pass" ]; then
        admin_pass=$(openssl rand -hex 8)
        ok "Admin password generated: $admin_pass"
    fi
    
    session_secret=$(openssl rand -hex 16)
    
    reading "Traffic collection interval seconds [20]: " traffic_interval
    traffic_interval=${traffic_interval:-20}
    
    reading "Traffic batch update size [10]: " traffic_batch_size
    traffic_batch_size=${traffic_batch_size:-10}
    
    reading "Task auto cleanup days [7]: " auto_cleanup_days
    auto_cleanup_days=${auto_cleanup_days:-7}
   
    reading "Enable Nginx reverse proxy plugin? y/n [y]: " nginx_enabled
    nginx_enabled=${nginx_enabled:-y}
    if [[ "$nginx_enabled" =~ ^[yY]$ ]]; then
        install_package nginx
        systemctl enable nginx >/dev/null 2>&1
        systemctl start nginx >/dev/null 2>&1
        ok "nginx installed and started"
        nginx_enabled_value="true"
   
        reading "Enable ACME certificate plugin? y/n [y]: " acme_enabled
        acme_enabled=${acme_enabled:-y}
        if [[ "$acme_enabled" =~ ^[yY]$ ]]; then
            acme_enabled_value="true"
        else
            acme_enabled_value="false"
        fi
    else
        warn "Nginx disabled, ACME plugin will also be disabled"
        nginx_enabled_value="false"
        acme_enabled_value="false"
    fi
   
    task_backend="memory"
    db_type="sqlite"
   
    info "Writing config..."
    sed -i "s|__SERVER_PORT__|$server_port|g" "$config_file"
    sed -i "s|__API_HASH__|$api_hash|g" "$config_file"
    sed -i "s|__ADMIN_USER__|$admin_user|g" "$config_file"
    sed -i "s|__ADMIN_PASS__|$admin_pass|g" "$config_file"
    sed -i "s|__SESSION_SECRET__|$session_secret|g" "$config_file"
    sed -i "s|__TRAFFIC_INTERVAL__|$traffic_interval|g" "$config_file"
    sed -i "s|__TRAFFIC_BATCH_SIZE__|$traffic_batch_size|g" "$config_file"
    sed -i "s|__AUTO_CLEANUP_DAYS__|$auto_cleanup_days|g" "$config_file"
    sed -i "s|__TASK_BACKEND__|$task_backend|g" "$config_file"
    sed -i "s|__DB_TYPE__|$db_type|g" "$config_file"
    sed -i "s|__REDIS_HOST__|localhost|g" "$config_file"
    sed -i "s|__REDIS_PORT__|6379|g" "$config_file"
    sed -i "s|__REDIS_PASSWORD__||g" "$config_file"
    sed -i "s|__REDIS_DB__|0|g" "$config_file"
    sed -i "s|__MYSQL_HOST__|localhost|g" "$config_file"
    sed -i "s|__MYSQL_PORT__|3306|g" "$config_file"
    sed -i "s|__MYSQL_USER__|root|g" "$config_file"
    sed -i "s|__MYSQL_PASSWORD__||g" "$config_file"
    sed -i "s|__MYSQL_DATABASE__|lxdapi|g" "$config_file"
    sed -i "s|__POSTGRES_HOST__|localhost|g" "$config_file"
    sed -i "s|__POSTGRES_PORT__|5432|g" "$config_file"
    sed -i "s|__POSTGRES_USER__|postgres|g" "$config_file"
    sed -i "s|__POSTGRES_PASSWORD__||g" "$config_file"
    sed -i "s|__POSTGRES_DATABASE__|lxdapi|g" "$config_file"
    sed -i "s|__POSTGRES_SSLMODE__|disable|g" "$config_file"
    sed -i "s|__NGINX_ENABLED__|$nginx_enabled_value|g" "$config_file"
    sed -i "s|__ACME_ENABLED__|$acme_enabled_value|g" "$config_file"
   
    ok "Config updated (SQLite & Memory mode)"
}

setup_lxdapi_service() {
    info "Configuring lxdapi system service..."
    
    config_file="/opt/lxdapi/configs/config.yaml"
    if [ ! -f "$config_file" ]; then
        err "Config file not found: $config_file"
    fi
    
    if grep -q "__SERVER_PORT__" "$config_file"; then
        err "Config file is not complete"
    fi
    
    sys_arch=$(uname -m)
    case $sys_arch in
        x86_64)
            exec_bin="/opt/lxdapi/lxdapi-amd64"
            ;;
        aarch64|arm64)
            exec_bin="/opt/lxdapi/lxdapi-arm64"
            ;;
        *)
            err "Unsupported architecture: $sys_arch"
            ;;
    esac
    
    service_file="/etc/systemd/system/lxdapi.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=LXD API Server
After=network.target lxd.service
Wants=lxd.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lxdapi
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
ExecStart=$exec_bin
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    ok "Service file created: $service_file"
    
    systemctl daemon-reload
    systemctl enable lxdapi
    systemctl start lxdapi
    
    info "Waiting for service startup..."
    for i in {1..10}; do
        printf "\r[%-10s] %d/10s" "$(printf '#%.0s' $(seq 1 $i))" "$i"
        sleep 1
    done
    echo
    
    if systemctl is-active --quiet lxdapi; then
        ok "lxdapi service started"
    else
        warn "lxdapi service startup failed"
        journalctl -u lxdapi -n 20 --no-pager
    fi
}

main() {
    echo
    echo "========================================"
    echo "        LXDAPI installer"
    echo "        by Github-lovejapan1"
    echo "========================================"
    echo
    
    echo "======== Step 1/5: Base packages ========"
    reading "Install base packages? (y/n) [y]: " step1_confirm
    step1_confirm=${step1_confirm:-y}
    if [[ "$step1_confirm" =~ ^[yY]$ ]]; then
        install_base_packages
        ok "Base packages ready"
    else
        info "Skipped base packages"
    fi
    echo

    echo "======== Step 2/5: Download ========"
    reading "Download lxdapi? (y/n) [y]: " step2_confirm
    step2_confirm=${step2_confirm:-y}
    if [[ "$step2_confirm" =~ ^[yY]$ ]]; then
        deploy_lxdapi
        ok "Download done"
    else
        info "Skipped download"
    fi
    echo

    echo "======== Step 3/5: Configure ========"
    reading "Configure lxdapi? (y/n) [y]: " step3_confirm
    step3_confirm=${step3_confirm:-y}
    if [[ "$step3_confirm" =~ ^[yY]$ ]]; then
        configure_lxdapi
        ok "Config done"
    else
        info "Skipped config"
    fi
    echo

    echo "======== Step 4/5: Start service ========"
    reading "Start lxdapi service? (y/n) [y]: " step4_confirm
    step4_confirm=${step4_confirm:-y}
    if [[ "$step4_confirm" =~ ^[yY]$ ]]; then
        setup_lxdapi_service
        ok "Service started"
    else
        info "Skipped service startup"
    fi
    echo

    echo "======== Step 5/5: Done ========"
    echo
    echo "========================================"
    echo "        LXDAPI install completed"
    echo "========================================"
    echo
    info "Service port: $server_port"
    info "API key: $api_hash"
    info "Admin user: $admin_user"
    info "Admin password: $admin_pass"
    info "Task queue: Memory"
    info "Database type: SQLite"
    info "Traffic interval: ${traffic_interval}s"
    echo
    systemctl status lxdapi --no-pager | head -5
}

main
