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
FIVEM_PROFILED_SCRIPT="${FIVEM_PROFILED_SCRIPT:-/etc/profile.d/kumahost-fivem-info.sh}"
FIVEM_INSTALL_LOG="/var/log/kumahost-fivem-install.log"
FIVEM_PIN=""
FIVEM_TXADMIN_URL=""
FIVEM_SERVER_DATA_PATH=""
FIVEM_DB_USER=""
FIVEM_DB_PASSWORD=""
FIVEM_DB_NAME=""
FIVEM_DB_CONN=""
FIVEM_DB_HOST="${FIVEM_DB_HOST:-127.0.0.1}"
FIVEM_DB_PORT="${FIVEM_DB_PORT:-3306}"
FIVEM_MYSQL_AUTO_SETUP="${FIVEM_MYSQL_AUTO_SETUP:-1}"
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

ensure_mysql_installed_and_running() {
    if [[ "$FIVEM_MYSQL_AUTO_SETUP" != "1" ]]; then
        return 0
    fi

    if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
        log "MySQL/MariaDB client not found; attempting installation..."
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y mariadb-server mariadb-client
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y mariadb-server mariadb
        elif command -v yum >/dev/null 2>&1; then
            yum install -y mariadb-server mariadb
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm mariadb
        elif command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive install mariadb mariadb-client
        else
            fail "No supported package manager found for MariaDB/MySQL install."
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files | grep -q '^mariadb\.service'; then
            systemctl enable --now mariadb || true
        elif systemctl list-unit-files | grep -q '^mysql\.service'; then
            systemctl enable --now mysql || true
        fi
    fi
}

mysql_exec() {
    local q="$1"
    if command -v mariadb >/dev/null 2>&1; then
        mariadb -N -B -e "$q"
    else
        mysql -N -B -e "$q"
    fi
}

random_token() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"
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
    {
        printf 'FIVEM_SERVER_IP=%q\n' "$ip"
        printf 'FIVEM_SERVER_DIR=%q\n' "$FIVEM_DIR"
        printf 'FIVEM_TXADMIN_PORT=%q\n' "40120"
        printf 'FIVEM_GAME_PORT=%q\n' "30120"
        printf 'FIVEM_TXADMIN_ENABLED=%q\n' "$txadmin_enabled"
        printf 'FIVEM_TXADMIN_URL=%q\n' "${FIVEM_TXADMIN_URL:-}"
        printf 'FIVEM_PIN=%q\n' "${FIVEM_PIN:-unknown}"
        printf 'FIVEM_PIN_NOTE=%q\n' "PIN is short-lived and may expire quickly after install."
        printf 'FIVEM_SERVER_DATA_PATH=%q\n' "${FIVEM_SERVER_DATA_PATH:-${FIVEM_DIR}/server-data}"
        printf 'FIVEM_DB_USER=%q\n' "${FIVEM_DB_USER:-}"
        printf 'FIVEM_DB_PASSWORD=%q\n' "${FIVEM_DB_PASSWORD:-}"
        printf 'FIVEM_DB_NAME=%q\n' "${FIVEM_DB_NAME:-}"
        printf 'FIVEM_DB_HOST=%q\n' "${FIVEM_DB_HOST:-127.0.0.1}"
        printf 'FIVEM_DB_PORT=%q\n' "${FIVEM_DB_PORT:-3306}"
        printf 'FIVEM_DB_CONN=%q\n' "${FIVEM_DB_CONN:-}"
    } > "$FIVEM_INFO_FILE"
    chmod 600 "$FIVEM_INFO_FILE"

    # Public banner data (no DB secrets), readable by normal users.
    umask 022
    {
        printf 'FIVEM_SERVER_IP=%q\n' "$ip"
        printf 'FIVEM_SERVER_DIR=%q\n' "$FIVEM_DIR"
        printf 'FIVEM_TXADMIN_PORT=%q\n' "40120"
        printf 'FIVEM_GAME_PORT=%q\n' "30120"
        printf 'FIVEM_TXADMIN_ENABLED=%q\n' "$txadmin_enabled"
        printf 'FIVEM_TXADMIN_URL=%q\n' "${FIVEM_TXADMIN_URL:-}"
        printf 'FIVEM_PIN=%q\n' "${FIVEM_PIN:-unknown}"
        printf 'FIVEM_PIN_NOTE=%q\n' "PIN is short-lived and may expire quickly after install."
        printf 'FIVEM_SERVER_DATA_PATH=%q\n' "${FIVEM_SERVER_DATA_PATH:-${FIVEM_DIR}/server-data}"
        # Intentionally included in public banner file because panel owner requested it.
        printf 'FIVEM_DB_USER=%q\n' "${FIVEM_DB_USER:-}"
        printf 'FIVEM_DB_PASSWORD=%q\n' "${FIVEM_DB_PASSWORD:-}"
        printf 'FIVEM_DB_NAME=%q\n' "${FIVEM_DB_NAME:-}"
        printf 'FIVEM_DB_HOST=%q\n' "${FIVEM_DB_HOST:-127.0.0.1}"
        printf 'FIVEM_DB_PORT=%q\n' "${FIVEM_DB_PORT:-3306}"
        printf 'FIVEM_DB_CONN=%q\n' "${FIVEM_DB_CONN:-}"
    } > "$FIVEM_INFO_PUBLIC_FILE"
    chmod 644 "$FIVEM_INFO_PUBLIC_FILE"
}

bootstrap_banner_files() {
    local ip txadmin_enabled
    ip="$(detect_public_ip)"
    txadmin_enabled="yes"
    if [[ "$FIVEM_NO_TXADMIN" == "1" ]]; then
        txadmin_enabled="no"
    fi

    if [[ ! -f "$FIVEM_INFO_FILE" ]]; then
        umask 077
        {
            printf 'FIVEM_SERVER_IP=%q\n' "$ip"
            printf 'FIVEM_SERVER_DIR=%q\n' "$FIVEM_DIR"
            printf 'FIVEM_TXADMIN_PORT=%q\n' "40120"
            printf 'FIVEM_GAME_PORT=%q\n' "30120"
            printf 'FIVEM_TXADMIN_ENABLED=%q\n' "$txadmin_enabled"
            printf 'FIVEM_TXADMIN_URL=%q\n' "${FIVEM_TXADMIN_URL:-}"
            printf 'FIVEM_PIN=%q\n' "${FIVEM_PIN:-unknown}"
            printf 'FIVEM_PIN_NOTE=%q\n' "PIN is short-lived and may expire quickly after install."
            printf 'FIVEM_SERVER_DATA_PATH=%q\n' "${FIVEM_SERVER_DATA_PATH:-${FIVEM_DIR}/server-data}"
            printf 'FIVEM_DB_USER=%q\n' "${FIVEM_DB_USER:-}"
            printf 'FIVEM_DB_PASSWORD=%q\n' "${FIVEM_DB_PASSWORD:-}"
            printf 'FIVEM_DB_NAME=%q\n' "${FIVEM_DB_NAME:-}"
            printf 'FIVEM_DB_HOST=%q\n' "${FIVEM_DB_HOST:-127.0.0.1}"
            printf 'FIVEM_DB_PORT=%q\n' "${FIVEM_DB_PORT:-3306}"
            printf 'FIVEM_DB_CONN=%q\n' "${FIVEM_DB_CONN:-}"
        } > "$FIVEM_INFO_FILE"
        chmod 600 "$FIVEM_INFO_FILE"
    fi

    if [[ ! -f "$FIVEM_INFO_PUBLIC_FILE" ]]; then
        umask 022
        {
            printf 'FIVEM_SERVER_IP=%q\n' "$ip"
            printf 'FIVEM_SERVER_DIR=%q\n' "$FIVEM_DIR"
            printf 'FIVEM_TXADMIN_PORT=%q\n' "40120"
            printf 'FIVEM_GAME_PORT=%q\n' "30120"
            printf 'FIVEM_TXADMIN_ENABLED=%q\n' "$txadmin_enabled"
            printf 'FIVEM_TXADMIN_URL=%q\n' "${FIVEM_TXADMIN_URL:-}"
            printf 'FIVEM_PIN=%q\n' "${FIVEM_PIN:-unknown}"
            printf 'FIVEM_PIN_NOTE=%q\n' "PIN is short-lived and may expire quickly after install."
            printf 'FIVEM_SERVER_DATA_PATH=%q\n' "${FIVEM_SERVER_DATA_PATH:-${FIVEM_DIR}/server-data}"
            printf 'FIVEM_DB_USER=%q\n' "${FIVEM_DB_USER:-}"
            printf 'FIVEM_DB_PASSWORD=%q\n' "${FIVEM_DB_PASSWORD:-}"
            printf 'FIVEM_DB_NAME=%q\n' "${FIVEM_DB_NAME:-}"
            printf 'FIVEM_DB_HOST=%q\n' "${FIVEM_DB_HOST:-127.0.0.1}"
            printf 'FIVEM_DB_PORT=%q\n' "${FIVEM_DB_PORT:-3306}"
            printf 'FIVEM_DB_CONN=%q\n' "${FIVEM_DB_CONN:-}"
        } > "$FIVEM_INFO_PUBLIC_FILE"
        chmod 644 "$FIVEM_INFO_PUBLIC_FILE"
    fi

    set_login_banner
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
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac
if [ -n "${KUMAHOST_FIVEM_BANNER_SHOWN:-}" ]; then
    return 0 2>/dev/null || true
fi
if [ -r /etc/fivem-server-info-public ]; then
    KUMAHOST_FIVEM_BANNER_SHOWN=1
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
    if [ -n "${FIVEM_DB_USER:-}" ] || [ -n "${FIVEM_DB_NAME:-}" ] || [ -n "${FIVEM_DB_CONN:-}" ]; then
        printf 'DB Host: \033[1;36m%s:%s\033[0m\n' "${FIVEM_DB_HOST:-127.0.0.1}" "${FIVEM_DB_PORT:-3306}"
        printf 'DB User: \033[1;36m%s\033[0m\n' "${FIVEM_DB_USER:-unknown}"
        printf 'DB Password: \033[1;31m%s\033[0m\n' "${FIVEM_DB_PASSWORD:-unknown}"
        printf 'DB Name: \033[1;36m%s\033[0m\n' "${FIVEM_DB_NAME:-unknown}"
        printf 'DB Conn: \033[1;33m%s\033[0m\n' "${FIVEM_DB_CONN:-unknown}"
    fi
    printf 'Scripts: \033[1;35mstart.sh stop.sh attach.sh\033[0m\n\n'
fi
# <<< kumahost-fivem-info <<<
EOF

    # Also install profile.d hook so banner appears on login shells even when bashrc path is skipped.
    cat > "$FIVEM_PROFILED_SCRIPT" <<'EOF'
#!/usr/bin/env sh
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac
if [ -n "${KUMAHOST_FIVEM_BANNER_SHOWN:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
if [ -r /etc/fivem-server-info-public ]; then
  KUMAHOST_FIVEM_BANNER_SHOWN=1
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
  if [ -n "${FIVEM_DB_USER:-}" ] || [ -n "${FIVEM_DB_NAME:-}" ] || [ -n "${FIVEM_DB_CONN:-}" ]; then
    printf 'DB Host: \033[1;36m%s:%s\033[0m\n' "${FIVEM_DB_HOST:-127.0.0.1}" "${FIVEM_DB_PORT:-3306}"
    printf 'DB User: \033[1;36m%s\033[0m\n' "${FIVEM_DB_USER:-unknown}"
    printf 'DB Password: \033[1;31m%s\033[0m\n' "${FIVEM_DB_PASSWORD:-unknown}"
    printf 'DB Name: \033[1;36m%s\033[0m\n' "${FIVEM_DB_NAME:-unknown}"
    printf 'DB Conn: \033[1;33m%s\033[0m\n' "${FIVEM_DB_CONN:-unknown}"
  fi
  printf 'Scripts: \033[1;35mstart.sh stop.sh attach.sh\033[0m\n\n'
fi
EOF
    chmod 755 "$FIVEM_PROFILED_SCRIPT"
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
        FIVEM_TXADMIN_URL="$(printf '%s' "$tx_line" | sed -nE 's#.*(https?://[^[:space:]]+).*#\1#p' | head -n1)"
    fi
    if [[ -n "$pin_line" ]]; then
        FIVEM_PIN="$(printf '%s' "$pin_line" | grep -oE '[0-9]{4,8}' | head -n1 || true)"
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

    # Fallback: some installers print raw numeric PIN on its own line.
    if [[ -z "${FIVEM_PIN:-}" || "${FIVEM_PIN:-}" == "unknown" ]]; then
        local pin_fallback
        pin_fallback="$(printf '%s\n' "$clean" | grep -E '^[[:space:]]*[0-9]{4,8}[[:space:]]*$' | tail -n1 | tr -d '[:space:]' || true)"
        if [[ -n "$pin_fallback" ]]; then
            FIVEM_PIN="$pin_fallback"
        fi
    fi
}

populate_db_fields_from_conn() {
    local conn="${FIVEM_DB_CONN:-}"
    [[ -n "$conn" ]] || return 0

    if [[ "$conn" =~ ^mysql://([^:]+):([^@]+)@([^/:?]+)(:([0-9]+))?/([^?]+) ]]; then
        FIVEM_DB_USER="${FIVEM_DB_USER:-${BASH_REMATCH[1]}}"
        FIVEM_DB_PASSWORD="${FIVEM_DB_PASSWORD:-${BASH_REMATCH[2]}}"
        FIVEM_DB_HOST="${FIVEM_DB_HOST:-${BASH_REMATCH[3]}}"
        FIVEM_DB_PORT="${FIVEM_DB_PORT:-${BASH_REMATCH[5]:-3306}}"
        FIVEM_DB_NAME="${FIVEM_DB_NAME:-${BASH_REMATCH[6]}}"
    fi
}

ensure_mysql_credentials() {
    if [[ "$FIVEM_MYSQL_AUTO_SETUP" != "1" ]]; then
        return 0
    fi

    ensure_mysql_installed_and_running

    if [[ -z "${FIVEM_DB_NAME:-}" ]]; then
        FIVEM_DB_NAME="fivem_$(random_token 8 | tr '[:upper:]' '[:lower:]')"
    fi
    if [[ -z "${FIVEM_DB_USER:-}" ]]; then
        FIVEM_DB_USER="fivem_$(random_token 8 | tr '[:upper:]' '[:lower:]')"
    fi
    if [[ -z "${FIVEM_DB_PASSWORD:-}" ]]; then
        FIVEM_DB_PASSWORD="$(random_token 24)"
    fi

    mysql_exec "CREATE DATABASE IF NOT EXISTS \`${FIVEM_DB_NAME}\`;" || return 1
    mysql_exec "CREATE USER IF NOT EXISTS '${FIVEM_DB_USER}'@'localhost' IDENTIFIED BY '${FIVEM_DB_PASSWORD}';" || return 1
    mysql_exec "CREATE USER IF NOT EXISTS '${FIVEM_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${FIVEM_DB_PASSWORD}';" || return 1
    mysql_exec "ALTER USER '${FIVEM_DB_USER}'@'localhost' IDENTIFIED BY '${FIVEM_DB_PASSWORD}';" || true
    mysql_exec "ALTER USER '${FIVEM_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${FIVEM_DB_PASSWORD}';" || true
    mysql_exec "GRANT ALL PRIVILEGES ON \`${FIVEM_DB_NAME}\`.* TO '${FIVEM_DB_USER}'@'localhost';" || return 1
    mysql_exec "GRANT ALL PRIVILEGES ON \`${FIVEM_DB_NAME}\`.* TO '${FIVEM_DB_USER}'@'127.0.0.1';" || return 1
    mysql_exec "FLUSH PRIVILEGES;" || true

    FIVEM_DB_CONN="mysql://${FIVEM_DB_USER}:${FIVEM_DB_PASSWORD}@${FIVEM_DB_HOST:-127.0.0.1}:${FIVEM_DB_PORT:-3306}/${FIVEM_DB_NAME}?charset=utf8mb4"
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
    if [[ -n "${FIVEM_DB_USER:-}" || -n "${FIVEM_DB_NAME:-}" || -n "${FIVEM_DB_CONN:-}" ]]; then
        log "Database credentials detected:"
        log "  Host: ${FIVEM_DB_HOST:-127.0.0.1}:${FIVEM_DB_PORT:-3306}"
        log "  User: ${FIVEM_DB_USER:-unknown}"
        log "  Password: ${FIVEM_DB_PASSWORD:-unknown}"
        log "  Database: ${FIVEM_DB_NAME:-unknown}"
        if [[ -n "${FIVEM_DB_CONN:-}" ]]; then
            log "  Connection: ${FIVEM_DB_CONN}"
        fi
    else
        log "No MySQL connection detected from installer output."
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
    ensure_mysql_installed_and_running
    if ! ensure_mysql_credentials; then
        log "WARNING: Initial MySQL credential setup failed; installer will continue."
    fi
    bootstrap_banner_files
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
    populate_db_fields_from_conn
    if ! ensure_mysql_credentials; then
        log "WARNING: MySQL credential setup failed; continuing without DB credentials."
    fi

    write_info_file
    set_login_banner
    print_summary
}

main "$@"
