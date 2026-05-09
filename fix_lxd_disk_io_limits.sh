#!/usr/bin/env bash
set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

LXC="/snap/bin/lxc"
TARGET="${1:-}"
LIMIT_KEYS=("limits.read" "limits.write" "limits.max")

info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERR] $*" >&2; }

find_lxc() {
    if [ -x "$LXC" ]; then
        return 0
    fi

    if command -v lxc >/dev/null 2>&1; then
        LXC="$(command -v lxc)"
        return 0
    fi

    err "lxc command not found. Please install and initialize LXD first."
    exit 1
}

unset_device_limits() {
    local scope="$1"
    local owner="$2"
    local device="$3"
    local changed=0
    local key

    for key in "${LIMIT_KEYS[@]}"; do
        if [ "$scope" = "profile" ]; then
            if "$LXC" profile device unset "$owner" "$device" "$key" >/dev/null 2>&1; then
                info "profile $owner device $device: removed $key"
                changed=1
            fi
        else
            if "$LXC" config device unset "$owner" "$device" "$key" >/dev/null 2>&1; then
                info "instance $owner device $device: removed $key"
                changed=1
            fi
        fi
    done

    return "$changed"
}

profile_devices() {
    "$LXC" profile device list "$1" 2>/dev/null | awk 'NF {print $1}'
}

instance_devices() {
    "$LXC" config device list "$1" 2>/dev/null | awk 'NF {print $1}'
}

clear_profile() {
    local profile="$1"
    local dev
    local devices

    devices="$(profile_devices "$profile")"
    if [ -z "$devices" ]; then
        return
    fi

    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        unset_device_limits "profile" "$profile" "$dev" || true
    done <<EOF
$devices
EOF
}

clear_all_profiles() {
    local profiles
    local profile

    profiles="$("$LXC" profile list --format csv -c n 2>/dev/null)"
    if [ -z "$profiles" ]; then
        return
    fi

    while IFS= read -r profile; do
        [ -n "$profile" ] || continue
        clear_profile "$profile"
    done <<EOF
$profiles
EOF
}

has_expanded_root_disk() {
    "$LXC" config show "$1" --expanded 2>/dev/null | awk '
        /^devices:/ {in_devices=1}
        in_devices && /^  root:/ {in_root=1}
        in_root && /^    type: disk/ {has_disk=1}
        in_root && /^    path: \// {has_path=1}
        in_root && /^  [^ ]/ && !/^  root:/ {in_root=0}
        END {exit !(has_disk && has_path)}
    '
}

clear_instance() {
    local instance="$1"
    local dev
    local devices

    if ! "$LXC" info "$instance" >/dev/null 2>&1; then
        warn "instance not found: $instance"
        return
    fi

    if has_expanded_root_disk "$instance"; then
        "$LXC" config device override "$instance" root >/dev/null 2>&1 || true
    fi

    devices="$(instance_devices "$instance")"
    devices="$(printf '%s\nroot\n' "$devices" | awk 'NF && !seen[$0]++')"

    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        unset_device_limits "instance" "$instance" "$dev" || true
    done <<EOF
$devices
EOF
}

clear_all_instances() {
    local instances
    local instance

    instances="$("$LXC" list --format csv -c n 2>/dev/null)"
    if [ -z "$instances" ]; then
        return
    fi

    while IFS= read -r instance; do
        [ -n "$instance" ] || continue
        clear_instance "$instance"
    done <<EOF
$instances
EOF
}

start_instance() {
    local instance="$1"

    info "starting $instance ..."
    if "$LXC" start "$instance"; then
        ok "started: $instance"
        return
    fi

    warn "start failed, showing LXD log:"
    "$LXC" info --show-log "$instance" || true
}

main() {
    find_lxc
    info "using lxc: $LXC"
    info "removing disk I/O limit keys from profiles..."
    clear_all_profiles

    if [ -n "$TARGET" ]; then
        info "removing disk I/O limit keys from instance: $TARGET"
        clear_instance "$TARGET"
        start_instance "$TARGET"
    else
        info "removing disk I/O limit keys from all instances..."
        clear_all_instances
        ok "done. Run: $LXC start <instance-name>"
    fi
}

main
