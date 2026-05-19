#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

REPO="lovejapan1/lxdapi_install"
CORE_COMMIT="a757673dfb300d6c9ff74f03b18358a2e1ac1987"
CORE_URL="https://raw.githubusercontent.com/${REPO}/${CORE_COMMIT}/install_all.sh"
INSTALL_DIR="/opt/lxdapi"

info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
ok() { echo -e "\033[0;32m[OK]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

fetch_core() {
    local tmp_file="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${CORE_URL}" -o "${tmp_file}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${tmp_file}" "${CORE_URL}"
    else
        echo "未找到 curl 或 wget，请先安装 curl" >&2
        exit 1
    fi
    chmod +x "${tmp_file}"
}

patch_panel_words() {
    [ -d "${INSTALL_DIR}" ] || return 0
    command -v perl >/dev/null 2>&1 || return 0
    find "${INSTALL_DIR}" -maxdepth 1 -type f -name 'lxdapi-*' 2>/dev/null | while read -r bin; do
        [ -n "${bin}" ] || continue
        cp -a "${bin}" "${bin}.bak_words" 2>/dev/null || true
        if perl -0pi -e 's/容器面板/服务器   /g; s/容器端口/服务端口/g; s/容器列表/服务列表/g; s/容器管理/服务管理/g; s/容器名称/服务名称/g; s/容器密码/服务密码/g; s/容器信息/服务信息/g; s/容器状态/服务状态/g; s/容器类型/服务类型/g; s/容器IP/服务IP/g; s/添加容器/添加服务/g; s/创建容器/创建服务/g; s/删除容器/删除服务/g; s/暂无容器/暂无服务/g;' "${bin}" 2>/dev/null; then
            rm -f "${bin}.bak_words"
        else
            mv -f "${bin}.bak_words" "${bin}" 2>/dev/null || true
        fi
        chmod +x "${bin}" 2>/dev/null || true
    done
}

patch_panel_background_ui() {
    [ -d "${INSTALL_DIR}" ] || return 0
    command -v perl >/dev/null 2>&1 || return 0

    local patch_script
    patch_script="$(mktemp)"
    cat >"${patch_script}" <<'PERL'
BEGIN {
    @pairs = (
        [q{admin_bg_opacity: parseInt($('#adminBgOpacity').val()),}, q{admin_bg_opacity:100-$('#adminBgOpacity').val(),}],
        [q{user_bg_opacity: parseInt($('#userBgOpacity').val()),}, q{user_bg_opacity:100-$('#userBgOpacity').val(),}],
        [q{container_bg_opacity: parseInt($('#containerBgOpacity').val()),}, q{container_bg_opacity:100-$('#containerBgOpacity').val(),}],
        [q{$('#adminBgOpacity').val(result.data.admin_bg_opacity || 75);}, q{$('#adminBgOpacity').val(100-result.data.admin_bg_opacity);}],
        [q{$('#adminOpacityValue').text((result.data.admin_bg_opacity || 75) + '%');}, q{$('#adminOpacityValue').text((100-result.data.admin_bg_opacity) + '%');}],
        [q{$('#userBgOpacity').val(result.data.user_bg_opacity || 75);}, q{$('#userBgOpacity').val(100-result.data.user_bg_opacity);}],
        [q{$('#userOpacityValue').text((result.data.user_bg_opacity || 75) + '%');}, q{$('#userOpacityValue').text((100-result.data.user_bg_opacity) + '%');}],
        [q{$('#containerBgOpacity').val(result.data.container_bg_opacity || 75);}, q{$('#containerBgOpacity').val(100-result.data.container_bg_opacity);}],
        [q{$('#containerOpacityValue').text((result.data.container_bg_opacity || 75) + '%');}, q{$('#containerOpacityValue').text((100-result.data.container_bg_opacity) + '%');}],
        [q{result.data.admin_content_opacity || 85}, q{result.data.admin_content_opacity ?? 85}],
        [q{result.data.user_content_opacity || 85}, q{result.data.user_content_opacity ?? 85}],
        [q{result.data.container_content_opacity || 85}, q{result.data.container_content_opacity ?? 85}],
        [q{result.data.user_notice_opacity || 85}, q{result.data.user_notice_opacity ?? 85}],
        [q{result.data.container_notice_opacity || 85}, q{result.data.container_notice_opacity ?? 85}],
    );
}

for my $pair (@pairs) {
    my ($from, $to) = @$pair;
    next if length($to) > length($from);
    $to .= ' ' x (length($from) - length($to));
    s/\Q$from\E/$to/g;
}
PERL

    find "${INSTALL_DIR}" -maxdepth 1 -type f -name 'lxdapi-*' 2>/dev/null | while read -r bin; do
        [ -n "${bin}" ] || continue
        cp -a "${bin}" "${bin}.bak_bg_ui" 2>/dev/null || true
        if perl -0pi "${patch_script}" "${bin}" 2>/dev/null; then
            rm -f "${bin}.bak_bg_ui"
        else
            mv -f "${bin}.bak_bg_ui" "${bin}" 2>/dev/null || true
        fi
        chmod +x "${bin}" 2>/dev/null || true
    done

    rm -f "${patch_script}"
}

restart_panel() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^lxdapi.service'; then
        systemctl restart lxdapi >/dev/null 2>&1 || true
    fi
}

apply_extra_fixes() {
    patch_panel_words
    patch_panel_background_ui
    restart_panel
    ok "面板品牌背景图 UI 已修复"
}

main() {
    local tmp_core
    tmp_core="$(mktemp /tmp/sakura-install-all-core.XXXXXX.sh)"
    trap 'rm -f "${tmp_core}"' EXIT

    fetch_core "${tmp_core}"
    bash "${tmp_core}" "$@"

    case "${1:-}" in
        install|all|panel|update|fix|repair|"")
            apply_extra_fixes
            ;;
    esac

    if [ "${1:-}" = "fix" ] || [ "${1:-}" = "repair" ]; then
        warn "背景图旧设置需要在后台品牌设置里重新点一次保存才会按新透明度逻辑写入"
    fi
}

main "$@"
