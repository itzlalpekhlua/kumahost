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
FIVEM_INFO_PUBLIC_FILE="${FIVEM_INFO_PUBLIC_FILE:-/etc/fivem-server-info-public}"
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
FIVEM_TMUX_KEEP_OPEN="${FIVEM_TMUX_KEEP_OPEN:-1}"
FIVEM_QGA_AUTO_DETECT="${FIVEM_QGA_AUTO_DETECT:-1}"
FIVEM_STAGED_SCRIPT_PATH="${FIVEM_STAGED_SCRIPT_PATH:-/tmp/kumahost-fivem-auto-installer.sh}"
FIVEM_TERM_DEFAULT="${FIVEM_TERM_DEFAULT:-xterm-256color}"

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

ensure_tmux_installed() {
    if command -v tmux >/dev/null 2>&1; then
        return 0
    fi

    log "tmux not found; attempting automatic install..."

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        local attempt
        for attempt in 1 2 3 4 5; do
            if apt-get update && apt-get install -y tmux; then
                break
            fi
            log "tmux install attempt ${attempt}/5 failed (apt). Retrying in 5s..."
            sleep 5
        done
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y tmux
    elif command -v yum >/dev/null 2>&1; then
        yum install -y tmux
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm tmux
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install tmux
    else
        fail "tmux is required, and no supported package manager was found (apt/dnf/yum/pacman/zypper)."
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        fail "tmux installation failed."
    fi
}

is_qga_context() {
    if [[ "$FIVEM_QGA_AUTO_DETECT" != "1" ]]; then
        return 1
    fi

    if [[ -t 0 || -t 1 ]]; then
        return 1
    fi

    local pcomm=""
    pcomm="$(cat "/proc/${PPID}/comm" 2>/dev/null || true)"
    [[ "$pcomm" == "qemu-ga" || "$pcomm" == "qemu-guest-agent" ]]
}

resolve_reexec_script_path() {
    local source_path="${BASH_SOURCE[0]:-$0}"
    local abs_path="$source_path"

    if [[ "$abs_path" != /* ]]; then
        abs_path="$(pwd)/$abs_path"
    fi

    # If already a normal file, use it directly.
    if [[ -f "$abs_path" && "$abs_path" != /dev/fd/* && "$abs_path" != /proc/*/fd/* ]]; then
        printf '%s' "$abs_path"
        return 0
    fi

    # One-click/piped execution often comes from /dev/fd/*.
    # Stage current script content to a stable file so tmux can re-exec it.
    if [[ -r "$source_path" ]]; then
        cat "$source_path" > "$FIVEM_STAGED_SCRIPT_PATH"
        chmod +x "$FIVEM_STAGED_SCRIPT_PATH"
        printf '%s' "$FIVEM_STAGED_SCRIPT_PATH"
        return 0
    fi

    if [[ -r "$abs_path" ]]; then
        cat "$abs_path" > "$FIVEM_STAGED_SCRIPT_PATH"
        chmod +x "$FIVEM_STAGED_SCRIPT_PATH"
        printf '%s' "$FIVEM_STAGED_SCRIPT_PATH"
        return 0
    fi

    return 1
}

run_in_tmux_if_needed() {
    if [[ "$FIVEM_TMUX_ENABLED" != "1" ]]; then
        return 0
    fi
    if [[ -n "${TMUX:-}" || "$FIVEM_IN_TMUX" == "1" ]]; then
        return 0
    fi

    ensure_tmux_installed

    local script_path=""
    if ! script_path="$(resolve_reexec_script_path)"; then
        log "Cannot resolve script file path for tmux re-exec (detected: ${BASH_SOURCE[0]:-$0})."
        log "Continuing in current shell."
        return 0
    fi

    local keep_open="$FIVEM_TMUX_KEEP_OPEN"
    if is_qga_context; then
        # In guest-agent runs, do not keep the session waiting for Enter.
        keep_open="0"
        log "QEMU guest-agent context detected; tmux session will auto-close after completion."
    fi

    local tmux_inner_cmd
    printf -v tmux_inner_cmd \
        'FIVEM_IN_TMUX=1 SETUP_URL=%q FIVEM_VERSION=%q FIVEM_ENABLE_CRONTAB=%q FIVEM_KILL_PORT=%q FIVEM_DELETE_DIR=%q FIVEM_NO_TXADMIN=%q FIVEM_DIR=%q FIVEM_INFO_FILE=%q DOWNLOAD_TIMEOUT_SECONDS=%q DOWNLOAD_RETRIES=%q FIVEM_TMUX_ENABLED=1 FIVEM_TMUX_SESSION=%q FIVEM_TMUX_KEEP_OPEN=%q FIVEM_QGA_AUTO_DETECT=%q bash %q' \
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
        "$keep_open" \
        "$FIVEM_QGA_AUTO_DETECT" \
        "$script_path"

    local tmux_cmd
    if [[ "$keep_open" == "1" ]]; then
        printf -v tmux_cmd \
            'bash -lc %q' \
            "${tmux_inner_cmd}; code=\$?; echo; echo '[KumaHost] Installer exited with code '\$code; echo '[KumaHost] Press Enter to close this tmux session.'; read -r _; exit \$code"
    else
        printf -v tmux_cmd 'bash -lc %q' "$tmux_inner_cmd"
    fi

    if tmux has-session -t "$FIVEM_TMUX_SESSION" 2>/dev/null; then
        log "A tmux install session already exists: $FIVEM_TMUX_SESSION"
        log "Attach with: tmux attach -t $FIVEM_TMUX_SESSION"
        log "If you ran installer as root, attach as root: sudo tmux attach -t $FIVEM_TMUX_SESSION"
        exit 0
    fi

    tmux new-session -d -s "$FIVEM_TMUX_SESSION" "$tmux_cmd"
    log "Installer started in tmux session: $FIVEM_TMUX_SESSION"
    log "Attach with: tmux attach -t $FIVEM_TMUX_SESSION"
    log "If you ran installer as root, attach as root: sudo tmux attach -t $FIVEM_TMUX_SESSION"
    log "Install log: $FIVEM_INSTALL_LOG"
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

    # Public banner data (no DB secrets), readable by normal users.
    umask 022
    cat > "$FIVEM_INFO_PUBLIC_FILE" <<EOF
FIVEM_SERVER_IP=${ip}
FIVEM_SERVER_DIR=${FIVEM_DIR}
FIVEM_TXADMIN_PORT=40120
FIVEM_GAME_PORT=30120
FIVEM_TXADMIN_ENABLED=${txadmin_enabled}
FIVEM_TXADMIN_URL=${FIVEM_TXADMIN_URL:-}
FIVEM_PIN=${FIVEM_PIN:-unknown}
FIVEM_PIN_NOTE=PIN is short-lived and may expire quickly after install.
FIVEM_SERVER_DATA_PATH=${FIVEM_SERVER_DATA_PATH:-${FIVEM_DIR}/server-data}
EOF
    chmod 644 "$FIVEM_INFO_PUBLIC_FILE"
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
if [ -n "$PS1" ] && [ -r /etc/fivem-server-info-public ]; then
    . /etc/fivem-server-info-public
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
    if [[ -z "${TERM:-}" || "${TERM:-}" == "dumb" ]]; then
        export TERM="$FIVEM_TERM_DEFAULT"
        log "TERM was missing/dumb; set TERM=${TERM} for non-interactive installer compatibility."
    fi
    ensure_tmux_installed
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
