#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/opt/lxdapi"
SERVICE_NAME="lxdapi"
SERVICE_FILE="/etc/systemd/system/lxdapi.service"

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

backup_panel() {
    if [ ! -d "$INSTALL_DIR" ]; then
        warn "未找到面板目录: $INSTALL_DIR"
        return 0
    fi

    reading "是否先备份面板目录？(y/n) [y]：" backup_confirm
    backup_confirm=${backup_confirm:-y}
    if [[ ! "$backup_confirm" =~ ^[yY]$ ]]; then
        warn "已跳过备份"
        return 0
    fi

    local backup_file
    backup_file="/root/lxdapi_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    info "正在备份到: $backup_file"
    tar -czf "$backup_file" -C /opt lxdapi || err "备份失败"
    ok "备份完成: $backup_file"
}

stop_service() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service" || [ -f "$SERVICE_FILE" ]; then
        info "停止并禁用 ${SERVICE_NAME} 服务..."
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
        warn "未找到 ${SERVICE_NAME} systemd 服务"
    fi
}

remove_service() {
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        ok "已删除服务文件: $SERVICE_FILE"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
}

remove_panel_files() {
    if [ ! -d "$INSTALL_DIR" ]; then
        warn "面板目录不存在，无需删除"
        return 0
    fi

    reading "确认删除面板目录 $INSTALL_DIR？不会删除 LXD/镜像/服务器 (y/n) [y]：" remove_confirm
    remove_confirm=${remove_confirm:-y}
    if [[ "$remove_confirm" =~ ^[yY]$ ]]; then
        rm -rf "$INSTALL_DIR"
        ok "已删除面板目录: $INSTALL_DIR"
    else
        warn "已保留面板目录: $INSTALL_DIR"
    fi
}

cleanup_nginx_configs() {
    local candidates=()
    local f

    for f in /etc/nginx/conf.d/lxdapi*.conf /etc/nginx/sites-enabled/lxdapi* /etc/nginx/sites-available/lxdapi*; do
        [ -e "$f" ] && candidates+=("$f")
    done

    if [ ${#candidates[@]} -eq 0 ]; then
        return 0
    fi

    warn "检测到可能的 lxdapi Nginx 配置:"
    printf '  %s\n' "${candidates[@]}"
    reading "是否删除这些 Nginx 配置？(y/n) [n]：" nginx_confirm
    nginx_confirm=${nginx_confirm:-n}
    if [[ "$nginx_confirm" =~ ^[yY]$ ]]; then
        rm -f "${candidates[@]}"
        ok "已删除 lxdapi Nginx 配置"
        if command -v nginx >/dev/null 2>&1; then
            nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || warn "Nginx 配置测试或重载失败，请手动检查"
        fi
    else
        warn "已保留 Nginx 配置"
    fi
}

main() {
    require_root

    echo
    echo "========================================"
    echo "        Sakura 面板卸载脚本"
    echo "========================================"
    echo
    warn "此脚本只卸载 Sakura/LXDAPI 面板，不删除 LXD、镜像和已创建的服务器。"
    echo

    reading "确认卸载 Sakura 面板？(y/n) [n]：" confirm
    confirm=${confirm:-n}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "已取消卸载"
        exit 0
    fi

    backup_panel
    stop_service
    remove_service
    cleanup_nginx_configs
    remove_panel_files

    echo
    ok "Sakura 面板卸载完成"
    info "LXD、镜像和已创建的服务器未被删除"
}

main "$@"
