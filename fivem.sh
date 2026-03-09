#!/usr/bin/env bash
set -Eeuo pipefail

# Wrapper around Twe3x FiveM installer.
# Runs in non-interactive mode for automation usage.

SETUP_URL="${SETUP_URL:-https://raw.githubusercontent.com/Twe3x/fivem-installer/main/setup.sh}"
FIVEM_VERSION="${FIVEM_VERSION:-latest}"
FIVEM_ENABLE_CRONTAB="${FIVEM_ENABLE_CRONTAB:-1}"
FIVEM_KILL_PORT="${FIVEM_KILL_PORT:-1}"
FIVEM_DELETE_DIR="${FIVEM_DELETE_DIR:-0}"
FIVEM_NO_TXADMIN="${FIVEM_NO_TXADMIN:-0}"
FIVEM_DIR="${FIVEM_DIR:-/home/FiveM}"
FIVEM_INFO_FILE="${FIVEM_INFO_FILE:-/etc/fivem-server-info}"
FIVEM_BASH_MARKER_START="# >>> kumahost-fivem-info >>>"
FIVEM_BASH_MARKER_END="# <<< kumahost-fivem-info <<<"

log() {
    printf '[%s] %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        fail "Run this script as root."
    fi
}

detect_public_ip() {
    local ip
    ip="$(curl -4fsS --max-time 4 https://api.ipify.org || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -6fsS --max-time 4 https://api64.ipify.org || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s' "${ip:-unknown}"
}

write_info_file() {
    local ip txadmin_enabled
    ip="$(detect_public_ip)"
    txadmin_enabled="yes"
    if [[ "$FIVEM_NO_TXADMIN" == "1" ]]; then
        txadmin_enabled="no"
    fi

    cat > "$FIVEM_INFO_FILE" <<EOF
FIVEM_SERVER_IP=${ip}
FIVEM_SERVER_DIR=${FIVEM_DIR}
FIVEM_TXADMIN_PORT=40120
FIVEM_GAME_PORT=30120
FIVEM_TXADMIN_ENABLED=${txadmin_enabled}
EOF
}

set_login_banner() {
    local bashrc="/etc/bash.bashrc"
    if [[ ! -f "$bashrc" && -f /etc/bashrc ]]; then
        bashrc="/etc/bashrc"
    fi

    if [[ ! -f "$bashrc" ]]; then
        log "Global bashrc file not found; skipping login banner."
        return
    fi

    sed -i "/${FIVEM_BASH_MARKER_START//\//\\/}/,/${FIVEM_BASH_MARKER_END//\//\\/}/d" "$bashrc"
    cat >> "$bashrc" <<'EOF'

# >>> kumahost-fivem-info >>>
if [ -n "$PS1" ] && [ -f /etc/fivem-server-info ]; then
    . /etc/fivem-server-info
    printf '\n\033[1;32mKumaHost FiveM Server Ready\033[0m\n'
    printf 'IP: \033[1;36m%s\033[0m\n' "${FIVEM_SERVER_IP:-unknown}"
    printf 'txAdmin: \033[1;33mhttp://%s:%s\033[0m\n' "${FIVEM_SERVER_IP:-unknown}" "${FIVEM_TXADMIN_PORT:-40120}"
    printf 'Game Port: \033[1;36m%s\033[0m (TCP/UDP)\n' "${FIVEM_GAME_PORT:-30120}"
    printf 'Directory: \033[1;34m%s\033[0m\n' "${FIVEM_SERVER_DIR:-/home/FiveM}"
    printf 'Scripts: \033[1;35mstart.sh stop.sh attach.sh\033[0m\n\n'
fi
# <<< kumahost-fivem-info <<<
EOF
}

print_summary() {
    local ip txadmin_url mode
    ip="$(detect_public_ip)"
    txadmin_url="http://${ip}:40120"
    mode="txAdmin deployment"
    if [[ "$FIVEM_NO_TXADMIN" == "1" ]]; then
        mode="cfx-server-data mode"
    fi

    log "FiveM installer finished."
    log "Mode: ${mode}"
    log "Server directory: ${FIVEM_DIR}"
    log "txAdmin URL: ${txadmin_url}"
    log "Game endpoint: ${ip}:30120 (TCP/UDP)"
    log "Helper scripts:"
    log "  Start: ${FIVEM_DIR}/start.sh"
    log "  Stop: ${FIVEM_DIR}/stop.sh"
    log "  Attach: ${FIVEM_DIR}/attach.sh"
    log "Screen session: screen -xS fivem"
}

main() {
    require_root

    command -v curl >/dev/null 2>&1 || fail "curl is required."
    command -v bash >/dev/null 2>&1 || fail "bash is required."

    local args=(
        --non-interactive
        --version "$FIVEM_VERSION"
    )

    if [[ "$FIVEM_ENABLE_CRONTAB" == "1" ]]; then
        args+=(--crontab)
    fi
    if [[ "$FIVEM_KILL_PORT" == "1" ]]; then
        args+=(--kill-port)
    fi
    if [[ "$FIVEM_DELETE_DIR" == "1" ]]; then
        args+=(--delete-dir)
    fi
    if [[ "$FIVEM_NO_TXADMIN" == "1" ]]; then
        args+=(--no-txadmin)
    fi

    log "Starting FiveM installer (non-interactive)..."
    log "Source: $SETUP_URL"
    log "Version: $FIVEM_VERSION"

    local tmp
    tmp="$(mktemp /tmp/fivem-setup.XXXXXX.sh)"
    trap 'rm -f "$tmp"' EXIT

    curl -fsSL "$SETUP_URL" -o "$tmp"
    chmod +x "$tmp"

    bash "$tmp" "${args[@]}"

    write_info_file
    set_login_banner
    print_summary
}

main "$@"
