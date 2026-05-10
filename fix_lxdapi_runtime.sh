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

CONFIG_FILE="/opt/lxdapi/configs/config.yaml"
SERVICE_NAME="lxdapi"
INSTANCE_NAME="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 用户执行"
fi

ensure_lxc_path() {
    if [ -x /snap/bin/lxc ]; then
        ln -sf /snap/bin/lxc /usr/local/bin/lxc
    fi
    hash -r 2>/dev/null || true

    if ! command -v lxc >/dev/null 2>&1; then
        err "未找到 lxc 命令，请先安装 LXD"
    fi
}

cleanup_instance() {
    local name="$1"
    [ -z "$name" ] && return 0

    info "检查 LXD 实例: $name"
    if lxc info "$name" >/dev/null 2>&1; then
        warn "发现 LXD 中存在 $name，正在删除这个残留实例"
        lxc delete -f "$name" || err "删除 LXD 实例失败: $name"
        ok "已删除 LXD 残留实例: $name"
    else
        ok "LXD 中不存在 $name，无需删除"
    fi
}

disable_acme() {
    if [ ! -f "$CONFIG_FILE" ]; then
        warn "配置文件不存在，跳过 ACME 修复: $CONFIG_FILE"
        return 0
    fi

    local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$backup_file" || err "备份配置失败"
    ok "配置已备份: $backup_file"

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
    ok "已关闭 ACME 插件，避免 IP 证书签发卡住服务"
}

restart_service() {
    pkill -f "acme.sh --issue" >/dev/null 2>&1 || true

    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
        systemctl restart "$SERVICE_NAME" || err "重启 $SERVICE_NAME 失败"
        sleep 3
        systemctl is-active --quiet "$SERVICE_NAME" || err "$SERVICE_NAME 未正常运行"
        ok "$SERVICE_NAME 已重启"
    else
        err "未找到 systemd 服务: ${SERVICE_NAME}.service"
    fi
}

show_status() {
    info "当前 LXD 实例列表"
    lxc list || true

    info "ACME 配置"
    grep -nA3 "acme:" "$CONFIG_FILE" || true

    info "服务状态"
    systemctl status "$SERVICE_NAME" --no-pager | head -12 || true

    info "最近日志"
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
}

main() {
    echo
    echo "========================================"
    echo "      Sakura/LXDAPI 运行时修复"
    echo "========================================"
    echo

    ensure_lxc_path
    cleanup_instance "$INSTANCE_NAME"
    disable_acme
    restart_service
    show_status

    echo
    ok "修复完成。现在可以回面板重新创建服务器"
    echo
    echo "如果要确认 API："
    echo "curl -k -H \"X-API-Hash: 你的API密钥\" https://127.0.0.1:8443/api/system/containers"
}

main "$@"
