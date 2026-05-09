#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "$1"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; exit 1; }

INSTALL_DIR="/opt/lxdapi"
CONFIG_FILE="$INSTALL_DIR/configs/config.yaml"
BACKUP_DIR="$INSTALL_DIR/backup"
SERVICE_NAME="lxdapi"

find_bin() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi

    for path in "/usr/bin/$name" "/bin/$name" "/usr/local/bin/$name"; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

download_file() {
    local url="$1"
    local output="$2"

    local wget_bin
    wget_bin=$(find_bin wget || true)
    if [ -n "$wget_bin" ]; then
        "$wget_bin" -q --show-progress -O "$output" "$url"
        return $?
    fi

    local curl_bin
    curl_bin=$(find_bin curl || true)
    if [ -n "$curl_bin" ]; then
        "$curl_bin" -LfsS --retry 3 -o "$output" "$url"
        return $?
    fi

    return 127
}

check_environment() {
    info "检测运行环境..."

    if [ ! -d "$INSTALL_DIR" ]; then
        err "未检测到 lxdapi 安装目录: $INSTALL_DIR"
    fi

    ok "环境检测通过"
}

detect_arch() {
    info "检测系统架构..."
    sys_arch=$(uname -m)
    case $sys_arch in
        x86_64|amd64)
            ARCH="amd64"
            ok "检测到架构: $sys_arch"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ok "检测到架构: $sys_arch"
            ;;
        *)
            err "不支持的架构: $sys_arch"
            ;;
    esac
}

get_current_version() {
    if [ -f "$INSTALL_DIR/lxdapi-$ARCH" ]; then
        CURRENT_VERSION=$(stat -c %y "$INSTALL_DIR/lxdapi-$ARCH" 2>/dev/null | cut -d' ' -f1)
    else
        CURRENT_VERSION="未安装"
    fi
    info "当前版本: $CURRENT_VERSION"
}

get_latest_version() {
    info "获取更新版本..."
    BASE_URL="https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main"
    LATEST_VERSION="Sakura-main"
    UPDATE_VERSION="Sakura-main"
    ok "更新版本: $UPDATE_VERSION"
}

stop_service() {
    info "停止 $SERVICE_NAME 服务..."

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            err "无法停止 $SERVICE_NAME 服务"
        fi
        ok "服务已停止"
    else
        warn "服务未运行"
    fi
}

backup_files() {
    info "备份当前文件..."

    BACKUP_TIME=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/$BACKUP_TIME"
    mkdir -p "$BACKUP_PATH"

    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$BACKUP_PATH/config.yaml"
        ok "配置文件已备份到: $BACKUP_PATH/config.yaml"
    fi

    if [ -f "$INSTALL_DIR/lxdapi-$ARCH" ]; then
        cp "$INSTALL_DIR/lxdapi-$ARCH" "$BACKUP_PATH/lxdapi-$ARCH"
        ok "二进制文件已备份"
    fi

    if [ -d "$INSTALL_DIR/certs" ]; then
        cp -r "$INSTALL_DIR/certs" "$BACKUP_PATH/certs"
        ok "证书文件已备份"
    fi

    if [ -f "$INSTALL_DIR/lxdapi.db" ]; then
        cp "$INSTALL_DIR/lxdapi.db" "$BACKUP_PATH/lxdapi.db"
        ok "数据库文件已备份"
    fi
}

download_latest() {
    info "下载版本 $UPDATE_VERSION..."

    DOWNLOAD_URL="${BASE_URL}/lxdapi-linux-${ARCH}.tar.gz"
    info "下载地址: $DOWNLOAD_URL"

    TEMP_FILE=$(mktemp)
    TEMP_DIR=$(mktemp -d)

    if download_file "$DOWNLOAD_URL" "$TEMP_FILE"; then
        ok "下载完成"
    else
        rm -f "$TEMP_FILE"
        rm -rf "$TEMP_DIR"
        err "下载失败: 请确认 wget 或 curl 可用"
    fi

    info "解压文件..."
    tar -xzf "$TEMP_FILE" -C "$TEMP_DIR" --strip-components=1

    if [ ! -f "$TEMP_DIR/lxdapi-$ARCH" ]; then
        rm -f "$TEMP_FILE"
        rm -rf "$TEMP_DIR"
        err "解压后未找到可执行文件"
    fi

    ok "解压完成"

    info "更新文件..."
    cp "$TEMP_DIR/lxdapi-$ARCH" "$INSTALL_DIR/lxdapi-$ARCH"
    chmod +x "$INSTALL_DIR/lxdapi-$ARCH"

    rm -f "$TEMP_FILE"
    rm -rf "$TEMP_DIR"

    ok "文件更新完成"
}

start_service() {
    info "启动 $SERVICE_NAME 服务..."

    systemctl daemon-reload
    systemctl start "$SERVICE_NAME"

    info "等待服务启动..."
    for i in {1..10}; do
        printf "\r[%-10s] %d/10s" "$(printf '#%.0s' $(seq 1 $i))" "$i"
        sleep 1
    done
    echo

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "服务已启动"
    else
        warn "服务启动失败，查看日志:"
        journalctl -u "$SERVICE_NAME" -n 10 --no-pager
        err "请检查配置或手动启动服务"
    fi
}

show_result() {
    echo
    echo "========================================"
    echo "        lxdapi 更新完成"
    echo "========================================"
    echo
    info "更新前版本: $CURRENT_VERSION"
    info "更新后版本: $UPDATE_VERSION"
    info "备份目录: $BACKUP_PATH"
    echo
    info "===== 服务状态 ====="
    systemctl status "$SERVICE_NAME" --no-pager | head -10
}

rollback() {
    warn "执行回滚..."

    if [ -z "$BACKUP_PATH" ] || [ ! -d "$BACKUP_PATH" ]; then
        err "无法回滚：备份目录不存在"
    fi

    if [ -f "$BACKUP_PATH/lxdapi-$ARCH" ]; then
        cp "$BACKUP_PATH/lxdapi-$ARCH" "$INSTALL_DIR/lxdapi-$ARCH"
        chmod +x "$INSTALL_DIR/lxdapi-$ARCH"
        ok "已恢复二进制文件"
    fi

    systemctl start "$SERVICE_NAME"
    ok "回滚完成"
}

main() {
    echo
    echo "========================================"
    echo "        LXDAPI 更新脚本"
    echo "        by Sakura"
    echo "========================================"
    echo

    check_environment
    detect_arch
    get_current_version
    get_latest_version

    echo
    read -rp "$(echo -e "${GREEN}确认更新? (y/n) [y]: ${NC}")" confirm
    confirm=${confirm:-y}

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "已取消更新"
        exit 0
    fi

    echo
    stop_service
    backup_files

    if download_latest; then
        start_service
        show_result
    else
        rollback
    fi
}

main "$@"
