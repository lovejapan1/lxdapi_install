#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
err() { echo "[ERR] $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err "Please run as root: sudo bash fix_lxd_image_tools.sh"
    exit 1
fi

install_with_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wget curl ca-certificates
}

install_with_dnf() {
    dnf install -y wget curl ca-certificates
}

install_with_yum() {
    yum install -y wget curl ca-certificates
}

install_with_zypper() {
    zypper --non-interactive install wget curl ca-certificates
}

install_with_pacman() {
    pacman -Sy --noconfirm wget curl ca-certificates
}

if command -v wget >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    ok "wget and curl already exist"
else
    log "Installing download tools required by the LXD image script..."
    if command -v apt-get >/dev/null 2>&1; then
        install_with_apt
    elif command -v dnf >/dev/null 2>&1; then
        install_with_dnf
    elif command -v yum >/dev/null 2>&1; then
        install_with_yum
    elif command -v zypper >/dev/null 2>&1; then
        install_with_zypper
    elif command -v pacman >/dev/null 2>&1; then
        install_with_pacman
    else
        err "No supported package manager found. Please install wget curl ca-certificates manually."
        exit 1
    fi
fi

if ! command -v wget >/dev/null 2>&1 && [ -x /usr/bin/wget ]; then
    ln -sf /usr/bin/wget /usr/local/bin/wget
fi

if ! command -v curl >/dev/null 2>&1 && [ -x /usr/bin/curl ]; then
    ln -sf /usr/bin/curl /usr/local/bin/curl
fi

hash -r 2>/dev/null || true

if ! command -v wget >/dev/null 2>&1; then
    err "wget is still unavailable. Please check PATH or package sources."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    err "curl is still unavailable. Please check PATH or package sources."
    exit 1
fi

ok "Download tools fixed"
echo "wget: $(command -v wget)"
echo "curl:  $(command -v curl)"
echo
echo "Now rerun the LXD image manager and import the image again."
