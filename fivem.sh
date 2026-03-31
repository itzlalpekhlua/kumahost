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
FIVEM_INSTALL_LOG="/var/log/kumahost-fivem-install.log"
FIVEM_PIN=""
FIVEM_TXADMIN_URL=""
FIVEM_SERVER_DATA_PATH=""
FIVEM_DB_USER=""
FIVEM_DB_PASSWORD=""
FIVEM_DB_NAME=""
FIVEM_DB_CONN=""
DOWNLOAD_TIMEOUT_SECONDS="${DOWNLOAD_TIMEOUT_SECONDS:-20}"
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-3}"
FIVEM_TMUX_ENABLED="${FIVEM_TMUX_ENABLED:-1}"
FIVEM_TMUX_SESSION="${FIVEM_TMUX_SESSION:-kumahost-fivem-install}"
FIVEM_IN_TMUX="${FIVEM_IN_TMUX:-0}"

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

run_in_tmux_if_needed() {
    if [[ "$FIVEM_TMUX_ENABLED" != "1" ]]; then
        return 0
    fi
    if [[ -n "${TMUX:-}" || "$FIVEM_IN_TMUX" == "1" ]]; then
        return 0
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        log "tmux not found; continuing without tmux session."
        return 0
    fi

    local script_path="$0"
    if [[ "$script_path" != /* ]]; then
        script_path="$(pwd)/$script_path"
    fi

    local tmux_cmd
    printf -v tmux_cmd \
        'FIVEM_IN_TMUX=1 SETUP_URL=%q FIVEM_VERSION=%q FIVEM_ENABLE_CRONTAB=%q FIVEM_KILL_PORT=%q FIVEM_DELETE_DIR=%q FIVEM_NO_TXADMIN=%q FIVEM_DIR=%q FIVEM_INFO_FILE=%q DOWNLOAD_TIMEOUT_SECONDS=%q DOWNLOAD_RETRIES=%q FIVEM_TMUX_ENABLED=1 FIVEM_TMUX_SESSION=%q bash %q' \
        "$SETUP_URL" \
        "$FIVEM_VERSION" \
        "$FIVEM_ENABLE_CRONTAB" \
        "$FIVEM_KILL_PORT" \
        "$FIVEM_DELETE_DIR" \
        "$FIVEM_NO_TXADMIN" \
        "$FIVEM_DIR" \
        "$FIVEM_INFO_FILE" \
        "$DOWNLOAD_TIMEOUT_SECONDS" \
        "$DOWNLOAD_RETRIES" \
        "$FIVEM_TMUX_SESSION" \
        "$script_path"

    if tmux has-session -t "$FIVEM_TMUX_SESSION" 2>/dev/null; then
        log "A tmux install session already exists: $FIVEM_TMUX_SESSION"
        log "Attach with: tmux attach -t $FIVEM_TMUX_SESSION"
        exit 0
    fi

    tmux new-session -d -s "$FIVEM_TMUX_SESSION" "$tmux_cmd"
    log "Installer started in tmux session: $FIVEM_TMUX_SESSION"
    log "Attach with: tmux attach -t $FIVEM_TMUX_SESSION"
    log "To run in foreground next time: FIVEM_TMUX_ENABLED=0 bash $script_path"
    exit 0
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

download_setup_script() {
    local out_file="$1"
    local attempts=0

    while (( attempts < DOWNLOAD_RETRIES )); do
        attempts=$((attempts + 1))
        if curl -fsSL \
            --connect-timeout "$DOWNLOAD_TIMEOUT_SECONDS" \
            --max-time $((DOWNLOAD_TIMEOUT_SECONDS * 3)) \
            "$SETUP_URL" \
            -o "$out_file"; then
            if head -n 1 "$out_file" | grep -Eq '^#!/'; then
                return 0
            fi
            log "Downloaded file from $SETUP_URL but it does not look executable."
        else
            log "Download attempt ${attempts}/${DOWNLOAD_RETRIES} failed."
        fi
        sleep 2
    done

    return 1
}

write_info_file() {
    local ip txadmin_enabled
    ip="$(detect_public_ip)"
    txadmin_enabled="yes"
    if [[ "$FIVEM_NO_TXADMIN" == "1" ]]; then
        txadmin_enabled="no"
    fi

    umask 077
    cat > "$FIVEM_INFO_FILE" <<EOF
FIVEM_SERVER_IP=${ip}
FIVEM_SERVER_DIR=${FIVEM_DIR}
FIVEM_TXADMIN_PORT=40120
FIVEM_GAME_PORT=30120
FIVEM_TXADMIN_ENABLED=${txadmin_enabled}
FIVEM_TXADMIN_URL=${FIVEM_TXADMIN_URL:-}
FIVEM_PIN=${FIVEM_PIN:-unknown}
FIVEM_PIN_NOTE=PIN is short-lived and may expire quickly after install.
FIVEM_SERVER_DATA_PATH=${FIVEM_SERVER_DATA_PATH:-${FIVEM_DIR}/server-data}
FIVEM_DB_USER=${FIVEM_DB_USER:-}
FIVEM_DB_PASSWORD=${FIVEM_DB_PASSWORD:-}
FIVEM_DB_NAME=${FIVEM_DB_NAME:-}
FIVEM_DB_CONN=${FIVEM_DB_CONN:-}
EOF
    chmod 600 "$FIVEM_INFO_FILE"
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
    if [ "${FIVEM_TXADMIN_ENABLED:-yes}" = "yes" ]; then
        _fivem_txadmin_display="${FIVEM_TXADMIN_URL:-http://${FIVEM_SERVER_IP:-unknown}:${FIVEM_TXADMIN_PORT:-40120}}"
    else
        _fivem_txadmin_display="disabled"
    fi
    printf '\n\033[1;32mKumaHost FiveM Server Ready\033[0m\n'
    printf 'IP: \033[1;36m%s\033[0m\n' "${FIVEM_SERVER_IP:-unknown}"
    printf 'txAdmin: \033[1;33m%s\033[0m\n' "${_fivem_txadmin_display}"
    printf 'PIN: \033[1;31m%s\033[0m\n' "${FIVEM_PIN:-unknown}"
    printf 'Note: \033[0;37m%s\033[0m\n' "${FIVEM_PIN_NOTE:-PIN may expire quickly}"
    printf 'Game Port: \033[1;36m%s\033[0m (TCP/UDP)\n' "${FIVEM_GAME_PORT:-30120}"
    printf 'Directory: \033[1;34m%s\033[0m\n' "${FIVEM_SERVER_DIR:-/home/FiveM}"
    printf 'Server Data: \033[1;34m%s\033[0m\n' "${FIVEM_SERVER_DATA_PATH:-/home/FiveM/server-data}"
    if [ -n "${FIVEM_DB_USER:-}" ] || [ -n "${FIVEM_DB_NAME:-}" ]; then
        printf 'DB User: \033[1;36m%s\033[0m\n' "${FIVEM_DB_USER:-unknown}"
        printf 'DB Password: \033[1;31m%s\033[0m\n' "${FIVEM_DB_PASSWORD:-unknown}"
        printf 'DB Name: \033[1;36m%s\033[0m\n' "${FIVEM_DB_NAME:-unknown}"
        if [ -n "${FIVEM_DB_CONN:-}" ]; then
            printf 'DB Conn: \033[1;33m%s\033[0m\n' "${FIVEM_DB_CONN}"
        fi
    fi
    printf 'Scripts: \033[1;35mstart.sh stop.sh attach.sh\033[0m\n\n'
fi
# <<< kumahost-fivem-info <<<
EOF
}

extract_runtime_details() {
    local log_file="$1"
    [[ -f "$log_file" ]] || return 0

    # Strip ANSI color codes for robust parsing.
    local clean
    clean="$(sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "$log_file")"

    local tx_line pin_line path_line
    tx_line="$(printf '%s\n' "$clean" | grep -E 'TxAdmin Webinterface:' | tail -n1 || true)"
    pin_line="$(printf '%s\n' "$clean" | grep -E '(^|[[:space:]])Pin:' | tail -n1 || true)"
    path_line="$(printf '%s\n' "$clean" | grep -E 'Server-Data Path:' | tail -n1 || true)"

    if [[ -n "$tx_line" ]]; then
        FIVEM_TXADMIN_URL="$(printf '%s' "$tx_line" | sed -E 's/.*TxAdmin Webinterface:[[:space:]]*//')"
    fi
    if [[ -n "$pin_line" ]]; then
        FIVEM_PIN="$(printf '%s' "$pin_line" | sed -E 's/.*Pin:[[:space:]]*//')"
    fi
    if [[ -n "$path_line" ]]; then
        FIVEM_SERVER_DATA_PATH="$(printf '%s' "$path_line" | sed -E 's/.*Server-Data Path:[[:space:]]*//')"
    fi

    local mysql_block
    mysql_block="$(printf '%s\n' "$clean" | awk '/FiveM MySQL-Data/{flag=1;next} flag && NF==0{exit} flag{print}')"
    if [[ -n "$mysql_block" ]]; then
        FIVEM_DB_USER="$(printf '%s\n' "$mysql_block" | sed -nE 's/^[[:space:]]*User:[[:space:]]*(.+)$/\1/p' | head -n1)"
        FIVEM_DB_PASSWORD="$(printf '%s\n' "$mysql_block" | sed -nE 's/^[[:space:]]*Password:[[:space:]]*(.+)$/\1/p' | head -n1)"
        FIVEM_DB_NAME="$(printf '%s\n' "$mysql_block" | sed -nE 's/^[[:space:]]*Database name:[[:space:]]*(.+)$/\1/p' | head -n1)"
        FIVEM_DB_CONN="$(printf '%s\n' "$mysql_block" | sed -nE 's/^[[:space:]]*set mysql_connection_string[[:space:]]+"(.*)".*$/\1/p' | head -n1)"
    fi

    FIVEM_TXADMIN_URL="${FIVEM_TXADMIN_URL//$'\r'/}"
    FIVEM_PIN="${FIVEM_PIN//$'\r'/}"
    FIVEM_SERVER_DATA_PATH="${FIVEM_SERVER_DATA_PATH//$'\r'/}"
}

print_summary() {
    local ip txadmin_url mode
    ip="$(detect_public_ip)"
    txadmin_url="${FIVEM_TXADMIN_URL:-disabled}"
    mode="txAdmin deployment"
    if [[ "$FIVEM_NO_TXADMIN" == "1" ]]; then
        mode="cfx-server-data mode"
    fi

    log "FiveM installer finished."
    log "Mode: ${mode}"
    log "Server directory: ${FIVEM_DIR}"
    log "txAdmin URL: ${txadmin_url}"
    log "PIN: ${FIVEM_PIN:-unknown}"
    log "Game endpoint: ${ip}:30120 (TCP/UDP)"
    log "Server data path: ${FIVEM_SERVER_DATA_PATH:-${FIVEM_DIR}/server-data}"
    if [[ -n "${FIVEM_DB_USER:-}" || -n "${FIVEM_DB_NAME:-}" ]]; then
        log "Database credentials detected:"
        log "  User: ${FIVEM_DB_USER:-unknown}"
        log "  Password: ${FIVEM_DB_PASSWORD:-unknown}"
        log "  Database: ${FIVEM_DB_NAME:-unknown}"
        if [[ -n "${FIVEM_DB_CONN:-}" ]]; then
            log "  Connection: ${FIVEM_DB_CONN}"
        fi
    fi
    log "Helper scripts:"
    log "  Start: ${FIVEM_DIR}/start.sh"
    log "  Stop: ${FIVEM_DIR}/stop.sh"
    log "  Attach: ${FIVEM_DIR}/attach.sh"
    log "Screen session: screen -xS fivem"
    log "Install session: tmux attach -t ${FIVEM_TMUX_SESSION}"
}

main() {
    require_root

    command -v curl >/dev/null 2>&1 || fail "curl is required."
    command -v bash >/dev/null 2>&1 || fail "bash is required."
    run_in_tmux_if_needed

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

    if ! download_setup_script "$tmp"; then
        fail "Failed to download setup script from $SETUP_URL after ${DOWNLOAD_RETRIES} attempts."
    fi
    chmod +x "$tmp"

    mkdir -p "$(dirname "$FIVEM_INSTALL_LOG")"
    : > "$FIVEM_INSTALL_LOG"
    bash "$tmp" "${args[@]}" 2>&1 | tee -a "$FIVEM_INSTALL_LOG"

    extract_runtime_details "$FIVEM_INSTALL_LOG"

    write_info_file
    set_login_banner
    print_summary
}

main "$@"
