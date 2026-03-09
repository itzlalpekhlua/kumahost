#!/usr/bin/env bash
set -Eeuo pipefail

MC_PORT="25565"
MC_MEMORY_GB="auto"
MC_VERSION="latest"
MC_USER="minecraft"
MC_GROUP="minecraft"
MC_DIR="/opt/minecraft"
MC_SERVICE_NAME="minecraft"
MC_JAR_NAME="server.jar"
MC_INFO_FILE="/etc/minecraft-server-info"
MC_BASH_MARKER_START="# >>> kumahost-minecraft-info >>>"
MC_BASH_MARKER_END="# <<< kumahost-minecraft-info <<<"
MC_JAVA_XMS="512M"
MC_JAVA_XMX="1024M"

log() {
    printf '[%s] %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        fail "Run this script as root (or with sudo)."
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        fail "No supported package manager found (apt, dnf, yum)."
    fi
}

detect_memory_limit_mb() {
    local host_mb cgroup_v2_mb cgroup_v1_mb limit_mb

    host_mb="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    cgroup_v2_mb=0
    cgroup_v1_mb=0

    if [[ -f /sys/fs/cgroup/memory.max ]]; then
        local v2
        v2="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
        if [[ "$v2" != "max" ]]; then
            cgroup_v2_mb=$(( v2 / 1024 / 1024 ))
        fi
    fi

    if [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        local v1
        v1="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)"
        if [[ "$v1" -gt 0 ]]; then
            cgroup_v1_mb=$(( v1 / 1024 / 1024 ))
        fi
    fi

    limit_mb="$host_mb"
    for candidate in "$cgroup_v2_mb" "$cgroup_v1_mb"; do
        if [[ "$candidate" -gt 0 && "$candidate" -lt "$limit_mb" ]]; then
            limit_mb="$candidate"
        fi
    done

    if [[ "$limit_mb" -lt 768 ]]; then
        limit_mb=768
    fi

    echo "$limit_mb"
}

calculate_java_memory() {
    local total_mb xmx_mb xms_mb
    total_mb="$(detect_memory_limit_mb)"

    if [[ "$MC_MEMORY_GB" == "auto" || -z "$MC_MEMORY_GB" ]]; then
        # Keep memory headroom for OS and background processes.
        xmx_mb=$(( total_mb * 70 / 100 ))
    else
        xmx_mb=$(( MC_MEMORY_GB * 1024 ))
    fi

    if [[ "$xmx_mb" -lt 768 ]]; then
        xmx_mb=768
    fi
    if [[ "$xmx_mb" -ge "$total_mb" ]]; then
        xmx_mb=$(( total_mb - 128 ))
    fi
    if [[ "$xmx_mb" -lt 768 ]]; then
        xmx_mb=768
    fi

    xms_mb=$(( xmx_mb / 2 ))
    if [[ "$xms_mb" -lt 512 ]]; then
        xms_mb=512
    fi
    if [[ "$xms_mb" -gt "$xmx_mb" ]]; then
        xms_mb="$xmx_mb"
    fi

    MC_JAVA_XMS="${xms_mb}M"
    MC_JAVA_XMX="${xmx_mb}M"
}

install_packages_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl wget jq gpg
}

install_packages_dnf() {
    dnf makecache -y
    dnf install -y ca-certificates curl wget jq
}

install_packages_yum() {
    yum makecache -y || true
    yum install -y ca-certificates curl wget jq
}

install_java_adoptium_apt() {
    install -d -m 0755 /etc/apt/keyrings
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
    chmod 0644 /etc/apt/keyrings/adoptium.gpg

    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    if [[ -z "$codename" ]]; then
        fail "Unable to determine distro codename for Adoptium apt repo."
    fi

    cat > /etc/apt/sources.list.d/adoptium.list <<EOF
deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${codename} main
EOF

    apt-get update -y
    apt-get install -y --no-install-recommends temurin-22-jdk
}

install_java_adoptium_rpm() {
    rpm --import https://packages.adoptium.net/artifactory/api/gpg/key/public
    cat > /etc/yum.repos.d/adoptium.repo <<'EOF'
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF
}

install_java_adoptium_dnf() {
    install_java_adoptium_rpm
    dnf makecache -y
    dnf install -y temurin-22-jdk
}

install_java_adoptium_yum() {
    install_java_adoptium_rpm
    yum makecache -y || true
    yum install -y temurin-22-jdk
}

ensure_java_and_tools() {
    local pkg_manager
    pkg_manager="$(detect_pkg_manager)"
    log "Detected package manager: ${pkg_manager}"

    case "$pkg_manager" in
        apt)
            install_packages_apt
            install_java_adoptium_apt
            ;;
        dnf)
            install_packages_dnf
            install_java_adoptium_dnf
            ;;
        yum)
            install_packages_yum
            install_java_adoptium_yum
            ;;
        *)
            fail "Unsupported package manager: ${pkg_manager}"
            ;;
    esac
}

setup_user_and_dirs() {
    if ! getent group "$MC_GROUP" >/dev/null 2>&1; then
        groupadd --system "$MC_GROUP"
    fi

    if ! id -u "$MC_USER" >/dev/null 2>&1; then
        useradd --system --gid "$MC_GROUP" --home "$MC_DIR" --shell /usr/sbin/nologin "$MC_USER"
    fi

    mkdir -p "$MC_DIR"
    chown -R "$MC_USER:$MC_GROUP" "$MC_DIR"
}

download_paper_server() {
    log "Fetching PaperMC metadata..."

    local version="$MC_VERSION"
    if [[ "$version" == "latest" ]]; then
        version="$(curl -fsSL https://api.papermc.io/v2/projects/paper \
            | jq -r '.versions[-1]')"
    fi

    if [[ -z "$version" || "$version" == "null" ]]; then
        fail "Could not resolve PaperMC version."
    fi

    local build
    build="$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${version}/builds" \
        | jq -r '.builds[-1].build')"
    if [[ -z "$build" || "$build" == "null" ]]; then
        fail "Could not resolve PaperMC build for version ${version}."
    fi

    local jar_name
    jar_name="$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${build}" \
        | jq -r '.downloads.application.name')"
    if [[ -z "$jar_name" || "$jar_name" == "null" ]]; then
        fail "Could not resolve PaperMC jar name for build ${build}."
    fi

    log "Downloading Paper ${version} build ${build}..."
    curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${build}/downloads/${jar_name}" \
        -o "${MC_DIR}/${MC_JAR_NAME}"

    cat > "${MC_DIR}/.kumahost-paper-version" <<EOF
PAPER_VERSION=${version}
PAPER_BUILD=${build}
EOF

    chown "$MC_USER:$MC_GROUP" "${MC_DIR}/${MC_JAR_NAME}" "${MC_DIR}/.kumahost-paper-version"
}

write_minecraft_files() {
    cat > "${MC_DIR}/eula.txt" <<'EOF'
eula=true
EOF

    cat > "${MC_DIR}/server.properties" <<EOF
server-port=${MC_PORT}
motd=KumaHost Minecraft Server
enable-query=false
online-mode=true
white-list=false
difficulty=normal
pvp=true
spawn-protection=0
max-players=20
view-distance=10
simulation-distance=10
EOF

    cat > "${MC_DIR}/start.sh" <<EOF
#!/usr/bin/env bash
cd "${MC_DIR}"
exec java -Xms${MC_JAVA_XMS} -Xmx${MC_JAVA_XMX} -jar ${MC_JAR_NAME} nogui
EOF

    chmod +x "${MC_DIR}/start.sh"
    chown "$MC_USER:$MC_GROUP" "${MC_DIR}/eula.txt" "${MC_DIR}/server.properties" "${MC_DIR}/start.sh"
}

write_systemd_service() {
    cat > "/etc/systemd/system/${MC_SERVICE_NAME}.service" <<EOF
[Unit]
Description=KumaHost Minecraft Server
After=network.target

[Service]
Type=simple
User=${MC_USER}
Group=${MC_GROUP}
WorkingDirectory=${MC_DIR}
ExecStart=${MC_DIR}/start.sh
Restart=always
RestartSec=5
SuccessExitStatus=0 1
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${MC_SERVICE_NAME}.service"
}

open_firewall_port() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            ufw allow "${MC_PORT}/tcp" >/dev/null 2>&1 || true
            log "Opened ufw port ${MC_PORT}/tcp."
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port="${MC_PORT}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            log "Opened firewalld port ${MC_PORT}/tcp."
        fi
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

set_login_banner() {
    local ip
    ip="$(detect_public_ip)"
    local paper_version="unknown"
    local paper_build="unknown"

    if [[ -f "${MC_DIR}/.kumahost-paper-version" ]]; then
        # shellcheck disable=SC1090
        . "${MC_DIR}/.kumahost-paper-version"
        paper_version="${PAPER_VERSION:-unknown}"
        paper_build="${PAPER_BUILD:-unknown}"
    fi

    cat > "$MC_INFO_FILE" <<EOF
MC_SERVER_IP=${ip}
MC_SERVER_PORT=${MC_PORT}
MC_SERVER_MEMORY_GB=${MC_MEMORY_GB}
MC_SERVER_JAVA_XMS=${MC_JAVA_XMS}
MC_SERVER_JAVA_XMX=${MC_JAVA_XMX}
MC_SERVER_DIR=${MC_DIR}
MC_PAPER_VERSION=${paper_version}
MC_PAPER_BUILD=${paper_build}
EOF

    local bashrc="/etc/bash.bashrc"
    if [[ ! -f "$bashrc" && -f /etc/bashrc ]]; then
        bashrc="/etc/bashrc"
    fi

    if [[ ! -f "$bashrc" ]]; then
        log "Global bashrc file not found; skipping login banner."
        return
    fi

    sed -i "/${MC_BASH_MARKER_START//\//\\/}/,/${MC_BASH_MARKER_END//\//\\/}/d" "$bashrc"
    cat >> "$bashrc" <<'EOF'

# >>> kumahost-minecraft-info >>>
if [ -n "$PS1" ] && [ -f /etc/minecraft-server-info ]; then
    . /etc/minecraft-server-info
    printf '\n\033[1;32mKumaHost Minecraft Server Ready\033[0m\n'
    printf 'IP: \033[1;36m%s\033[0m\n' "${MC_SERVER_IP:-unknown}"
    printf 'Port: \033[1;36m%s\033[0m\n' "${MC_SERVER_PORT:-25565}"
    printf 'Java RAM: \033[1;35mXms=%s Xmx=%s\033[0m\n' "${MC_SERVER_JAVA_XMS:-512M}" "${MC_SERVER_JAVA_XMX:-1024M}"
    printf 'Paper: \033[1;35m%s (build %s)\033[0m\n' "${MC_PAPER_VERSION:-unknown}" "${MC_PAPER_BUILD:-unknown}"
    printf 'Directory: \033[1;34m%s\033[0m\n' "${MC_SERVER_DIR:-/opt/minecraft}"
    printf 'Connect: \033[1;33m%s:%s\033[0m\n\n' "${MC_SERVER_IP:-unknown}" "${MC_SERVER_PORT:-25565}"
fi
# <<< kumahost-minecraft-info <<<
EOF
}

print_summary() {
    local ip
    ip="$(detect_public_ip)"
    log "Installation completed."
    log "Minecraft service: ${MC_SERVICE_NAME}.service"
    log "Java memory: Xms=${MC_JAVA_XMS}, Xmx=${MC_JAVA_XMX}"
    log "Server directory: ${MC_DIR}"
    log "Connect using: ${ip}:${MC_PORT}"
    log "Check status: systemctl status ${MC_SERVICE_NAME}"
    log "View logs: journalctl -u ${MC_SERVICE_NAME} -f"
}

main() {
    require_root
    ensure_java_and_tools
    setup_user_and_dirs
    calculate_java_memory
    download_paper_server
    write_minecraft_files
    write_systemd_service
    open_firewall_port
    set_login_banner
    print_summary
}

main "$@"
