#!/usr/bin/env bash

# ============================================================
# PICASO GRE MANAGER
# Multi-Tunnel GRE Management System
#
# Features:
#   - Multiple independent GRE tunnels
#   - Add / Start / Stop / Restart / Delete
#   - Test / Details / Traffic
#   - Persistent configuration
#   - Automatic restore after reboot
#   - Health monitor
#   - Repair / Synchronize
#   - BBR optimization
#   - Network optimization
#   - Safe uninstall
#
# Default tunnel network:
#   132.168.30.0/30
#   132.168.31.0/30
#   132.168.32.0/30
#   ...
#
# Interface:
#   picaso-gre1
#   picaso-gre2
#   ...
#
# ============================================================

set -u

VERSION="1.0.0"

BASE_DIR="/etc/picaso"
TUNNEL_DIR="${BASE_DIR}/tunnels"
STATE_FILE="${BASE_DIR}/manager.conf"

BIN="/usr/local/bin/picaso"
RESTORE_BIN="/usr/local/sbin/picaso-restore"
MONITOR_BIN="/usr/local/sbin/picaso-monitor"

LOG_FILE="/var/log/picaso.log"

RESTORE_SERVICE="/etc/systemd/system/picaso-restore.service"
MONITOR_SERVICE="/etc/systemd/system/picaso-monitor.service"

BASE_SUBNET=30
MTU_DEFAULT=1476

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
RESET='\033[0m'

# ------------------------------------------------------------
# Basic helpers
# ------------------------------------------------------------

msg() {
    echo -e "${CYAN}$*${RESET}"
}

success() {
    echo -e "${GREEN}✓ $*${RESET}"
}

warning() {
    echo -e "${YELLOW}! $*${RESET}"
}

error() {
    echo -e "${RED}✗ $*${RESET}"
}

die() {
    error "$*"
    exit 1
}

pause_screen() {
    echo
    read -rp "Press Enter to continue..." _
}

log_msg() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "This script must be run as root."
        exit 1
    fi
}

# ------------------------------------------------------------
# Dependency installation
# ------------------------------------------------------------

install_dependencies() {

    local packages=(
        iproute2
        iputils-ping
        procps
        curl
        grep
        sed
        awk
        coreutils
        util-linux
    )

    msg "Checking dependencies..."

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1

        apt-get install -y \
            iproute2 \
            iputils-ping \
            procps \
            curl \
            grep \
            sed \
            gawk \
            coreutils \
            util-linux \
            >/dev/null 2>&1

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            iproute \
            iputils \
            procps-ng \
            curl \
            grep \
            sed \
            gawk \
            coreutils \
            util-linux \
            >/dev/null 2>&1

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            iproute \
            iputils \
            procps-ng \
            curl \
            grep \
            sed \
            gawk \
            coreutils \
            util-linux \
            >/dev/null 2>&1

    else
        warning "Unknown package manager."
        warning "Please make sure required commands are installed."
    fi

    success "Dependencies checked."
}

# ------------------------------------------------------------
# Initialization
# ------------------------------------------------------------

initialize_picaso() {

    mkdir -p "$BASE_DIR"
    mkdir -p "$TUNNEL_DIR"

    touch "$LOG_FILE"

    if [[ ! -f "$STATE_FILE" ]]; then

        cat > "$STATE_FILE" <<EOF
PICASO_VERSION="$VERSION"
NEXT_ID=1
EOF

    fi
}

# ------------------------------------------------------------
# IPv4 validation
# ------------------------------------------------------------

valid_ipv4() {

    local ip="$1"

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r a b c d <<< "$ip"

    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

# ------------------------------------------------------------
# Public IP detection
# ------------------------------------------------------------

detect_public_ip() {

    local ip=""

    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi

    if valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
        {
            for(i=1;i<=NF;i++)
                if($i=="src") {
                    print $(i+1)
                    exit
                }
        }
    ')"

    if valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# ID handling
# ------------------------------------------------------------

get_next_id() {

    local next

    next="$(grep '^NEXT_ID=' "$STATE_FILE" 2>/dev/null |
        tail -n1 |
        cut -d= -f2)"

    if [[ "$next" =~ ^[0-9]+$ ]] && (( next > 0 )); then
        echo "$next"
        return
    fi

    echo 1
}

save_next_id() {

    local id="$1"

    if grep -q '^NEXT_ID=' "$STATE_FILE"; then

        sed -i "s/^NEXT_ID=.*/NEXT_ID=$id/" "$STATE_FILE"

    else

        echo "NEXT_ID=$id" >> "$STATE_FILE"

    fi
}

interface_name() {
    echo "picaso-gre$1"
}

config_file() {
    echo "${TUNNEL_DIR}/$1.conf"
}

# ------------------------------------------------------------
# Tunnel subnet calculation
# ------------------------------------------------------------

calculate_subnet() {

    local id="$1"

    # ID 1 => 132.168.30.0/30
    # ID 2 => 132.168.31.0/30
    # ...
    #
    # Keep the third octet in valid IPv4 range.

    local third=$((BASE_SUBNET + id - 1))

    if (( third > 254 )); then
        return 1
    fi

    echo "132.168.${third}.0"
}

local_tunnel_ip() {

    local subnet="$1"
    local role="$2"

    if [[ "$role" == "iran" ]]; then
        echo "${subnet%.*}.2"
    else
        echo "${subnet%.*}.1"
    fi
}

remote_tunnel_ip() {

    local subnet="$1"
    local role="$2"

    if [[ "$role" == "iran" ]]; then
        echo "${subnet%.*}.1"
    else
        echo "${subnet%.*}.2"
    fi
}

# ------------------------------------------------------------
# Config reading
# ------------------------------------------------------------

load_config() {

    local id="$1"
    local file

    file="$(config_file "$id")"

    [[ -f "$file" ]] || return 1

    # shellcheck disable=SC1090
    source "$file"

    return 0
}

# ------------------------------------------------------------
# Check whether an ID is used
# ------------------------------------------------------------

id_exists() {

    local id="$1"

    [[ -f "$(config_file "$id")" ]]
}

# ------------------------------------------------------------
# Check whether interface exists
# ------------------------------------------------------------

interface_exists() {

    local iface="$1"

    ip link show "$iface" >/dev/null 2>&1
}

# ------------------------------------------------------------
# Check whether public IP is already used
# ------------------------------------------------------------

remote_ip_exists() {

    local remote="$1"
    local file

    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -f "$file" ]] || continue

        unset REMOTE_PUBLIC_IP

        # shellcheck disable=SC1090
        source "$file"

        if [[ "${REMOTE_PUBLIC_IP:-}" == "$remote" ]]; then
            return 0
        fi

    done

    return 1
}

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

firewall_add() {

    local remote="$1"
    local iface="$2"

    if command -v iptables >/dev/null 2>&1; then

        if ! iptables -C INPUT \
            -p 47 \
            -s "$remote" \
            -m comment \
            --comment "PICASO-GRE-$iface" \
            -j ACCEPT 2>/dev/null; then

            iptables -I INPUT 1 \
                -p 47 \
                -s "$remote" \
                -m comment \
                --comment "PICASO-GRE-$iface" \
                -j ACCEPT
        fi

        if ! iptables -C INPUT \
            -i "$iface" \
            -m comment \
            --comment "PICASO-TUNNEL-$iface" \
            -j ACCEPT 2>/dev/null; then

            iptables -I INPUT 1 \
                -i "$iface" \
                -m comment \
                --comment "PICASO-TUNNEL-$iface" \
                -j ACCEPT
        fi

        if ! iptables -C FORWARD \
            -i "$iface" \
            -m comment \
            --comment "PICASO-FWD-IN-$iface" \
            -j ACCEPT 2>/dev/null; then

            iptables -I FORWARD 1 \
                -i "$iface" \
                -m comment \
                --comment "PICASO-FWD-IN-$iface" \
                -j ACCEPT
        fi

        if ! iptables -C FORWARD \
            -o "$iface" \
            -m comment \
            --comment "PICASO-FWD-OUT-$iface" \
            -j ACCEPT 2>/dev/null; then

            iptables -I FORWARD 1 \
                -o "$iface" \
                -m comment \
                --comment "PICASO-FWD-OUT-$iface" \
                -j ACCEPT
        fi

        log_msg "Firewall rules added for $iface"
    fi
}

firewall_remove() {

    local remote="$1"
    local iface="$2"

    if ! command -v iptables >/dev/null 2>&1; then
        return
    fi

    while iptables -C INPUT \
        -p 47 \
        -s "$remote" \
        -m comment \
        --comment "PICASO-GRE-$iface" \
        -j ACCEPT 2>/dev/null; do

        iptables -D INPUT \
            -p 47 \
            -s "$remote" \
            -m comment \
            --comment "PICASO-GRE-$iface" \
            -j ACCEPT

    done

    while iptables -C INPUT \
        -i "$iface" \
        -m comment \
        --comment "PICASO-TUNNEL-$iface" \
        -j ACCEPT 2>/dev/null; do

        iptables -D INPUT \
            -i "$iface" \
            -m comment \
            --comment "PICASO-TUNNEL-$iface" \
            -j ACCEPT

    done

    while iptables -C FORWARD \
        -i "$iface" \
        -m comment \
        --comment "PICASO-FWD-IN-$iface" \
        -j ACCEPT 2>/dev/null; do

        iptables -D FORWARD \
            -i "$iface" \
            -m comment \
            --comment "PICASO-FWD-IN-$iface" \
            -j ACCEPT

    done

    while iptables -C FORWARD \
        -o "$iface" \
        -m comment \
        --comment "PICASO-FWD-OUT-$iface" \
        -j ACCEPT 2>/dev/null; do

        iptables -D FORWARD \
            -o "$iface" \
            -m comment \
            --comment "PICASO-FWD-OUT-$iface" \
            -j ACCEPT

    done

    log_msg "Firewall rules removed for $iface"
}

# ------------------------------------------------------------
# Enable forwarding
# ------------------------------------------------------------

enable_forwarding() {

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    mkdir -p /etc/sysctl.d

    cat > /etc/sysctl.d/99-picaso-forwarding.conf <<EOF
net.ipv4.ip_forward = 1
EOF

    sysctl --system >/dev/null 2>&1 || true

    success "IPv4 forwarding enabled."
}

# ------------------------------------------------------------
# Create tunnel
# ------------------------------------------------------------

create_tunnel() {

    local id="$1"

    load_config "$id" || {
        error "Configuration for tunnel $id not found."
        return 1
    }

    local iface="$INTERFACE"

    if interface_exists "$iface"; then

        warning "$iface already exists."

        # Do not touch an existing interface blindly.
        return 0
    fi

    msg "Creating $iface..."

    ip tunnel add "$iface" \
        mode gre \
        local "$LOCAL_PUBLIC_IP" \
        remote "$REMOTE_PUBLIC_IP" \
        ttl 255

    if [[ $? -ne 0 ]]; then
        error "Failed to create $iface."
        log_msg "ERROR: failed to create $iface"
        return 1
    fi

    ip link set "$iface" mtu "${MTU:-$MTU_DEFAULT}"

    ip addr add "${LOCAL_TUNNEL_IP}/30" dev "$iface"

    ip link set "$iface" up

    firewall_add "$REMOTE_PUBLIC_IP" "$iface"

    success "$iface created."

    log_msg "Tunnel $id ($iface) created."

    return 0
}

# ------------------------------------------------------------
# Start tunnel
# ------------------------------------------------------------

start_tunnel() {

    local id="$1"

    load_config "$id" || {
        error "Tunnel $id configuration not found."
        return 1
    }

    if ! interface_exists "$INTERFACE"; then
        create_tunnel "$id" || return 1
    fi

    ip link set "$INTERFACE" up 2>/dev/null || true

    success "Tunnel $id started."

    log_msg "Tunnel $id started."
}

# ------------------------------------------------------------
# Stop tunnel
# ------------------------------------------------------------

stop_tunnel() {

    local id="$1"

    load_config "$id" || {
        error "Tunnel $id configuration not found."
        return 1
    }

    if interface_exists "$INTERFACE"; then

        ip link set "$INTERFACE" down 2>/dev/null || true

        success "Tunnel $id stopped."

        log_msg "Tunnel $id stopped."

    else

        warning "Tunnel $id is already stopped."

    fi
}

# ------------------------------------------------------------
# Restart tunnel
# ------------------------------------------------------------

restart_tunnel() {

    local id="$1"

    load_config "$id" || {
        error "Tunnel $id configuration not found."
        return 1
    }

    msg "Restarting tunnel $id..."

    stop_tunnel "$id" >/dev/null 2>&1 || true

    sleep 1

    if interface_exists "$INTERFACE"; then

        ip link set "$INTERFACE" down 2>/dev/null || true

        ip link delete "$INTERFACE" 2>/dev/null || true

    fi

    create_tunnel "$id" || return 1

    success "Tunnel $id restarted."

    log_msg "Tunnel $id restarted."
}

# ------------------------------------------------------------
# Delete tunnel
# ------------------------------------------------------------

delete_tunnel() {

    local id="$1"

    load_config "$id" || {
        error "Tunnel $id configuration not found."
        return 1
    }

    echo
    warning "You are about to delete:"
    echo
    echo "  ID          : $id"
    echo "  Interface   : $INTERFACE"
    echo "  Remote IP   : $REMOTE_PUBLIC_IP"
    echo "  Tunnel IP   : $LOCAL_TUNNEL_IP"
    echo

    read -rp "Type DELETE to confirm: " confirm

    if [[ "$confirm" != "DELETE" ]]; then
        warning "Cancelled."
        return
    fi

    firewall_remove "$REMOTE_PUBLIC_IP" "$INTERFACE"

    if interface_exists "$INTERFACE"; then
        ip link delete "$INTERFACE" 2>/dev/null || true
    fi

    rm -f "$(config_file "$id")"

    success "Tunnel $id deleted."

    log_msg "Tunnel $id deleted."

}

# ------------------------------------------------------------
# Test tunnel
# ------------------------------------------------------------

test_tunnel() {

    local id="$1"

    load_config "$id" || {
        error "Tunnel $id not found."
        return 1
    }

    echo
    echo "----------------------------------------------"
    echo " Tunnel Test: $INTERFACE"
    echo "----------------------------------------------"

    if ! interface_exists "$INTERFACE"; then
        error "Interface does not exist."
        return 1
    fi

    echo
    ip -br addr show "$INTERFACE"

    echo
    msg "Testing remote tunnel IP: $REMOTE_TUNNEL_IP"

    if ping -I "$INTERFACE" -c 4 -W 2 "$REMOTE_TUNNEL_IP"; then

        success "Tunnel connectivity: OK"

        log_msg "Tunnel $id connectivity OK"

        return 0

    else

        error "Tunnel connectivity: FAILED"

        log_msg "Tunnel $id connectivity FAILED"

        return 1
    fi
}

# ------------------------------------------------------------
# Details
# ------------------------------------------------------------

show_details() {

    local id="$1"

    load_config "$id" || {
        error "Tunnel $id not found."
        return 1
    }

    echo
    echo "========================================================"
    echo "                  TUNNEL DETAILS"
    echo "========================================================"
    echo
    echo "ID              : $ID"
    echo "Name            : $NAME"
    echo "Role            : $ROLE"
    echo "Interface       : $INTERFACE"
    echo "Local Public IP : $LOCAL_PUBLIC_IP"
    echo "Remote Public IP: $REMOTE_PUBLIC_IP"
    echo "Subnet          : $SUBNET/30"
    echo "Local Tunnel IP : $LOCAL_TUNNEL_IP"
    echo "Remote Tunnel IP: $REMOTE_TUNNEL_IP"
    echo "MTU             : $MTU"
    echo

    echo "IP tunnel:"
    ip tunnel show "$INTERFACE" 2>/dev/null || true

    echo
    echo "Interface:"
    ip -details link show "$INTERFACE" 2>/dev/null || true

    echo
    echo "Address:"
    ip addr show "$INTERFACE" 2>/dev/null || true

    echo
    echo "Route:"
    ip route get "$REMOTE_TUNNEL_IP" 2>/dev/null || true

    echo
}

# ------------------------------------------------------------
# Traffic
# ------------------------------------------------------------

show_traffic() {

    local id="$1"

    load_config "$id" || {
        error "Tunnel $id not found."
        return 1
    }

    if ! interface_exists "$INTERFACE"; then
        error "Interface does not exist."
        return 1
    fi

    echo
    echo "========================================================"
    echo "                  TRAFFIC: $INTERFACE"
    echo "========================================================"
    echo

    ip -s link show "$INTERFACE"
}

# ------------------------------------------------------------
# Tunnel status
# ------------------------------------------------------------

get_tunnel_status() {

    local id="$1"

    load_config "$id" || {
        echo "MISSING"
        return
    }

    if ! interface_exists "$INTERFACE"; then
        echo "DOWN"
        return
    fi

    if ip link show "$INTERFACE" 2>/dev/null |
        grep -q "state UP"; then

        echo "UP"

    else

        echo "DOWN"

    fi
}

# ------------------------------------------------------------
# List tunnels
# ------------------------------------------------------------

list_tunnels() {

    local found=0
    local file
    local id

    echo
    echo "========================================================"
    echo "                     PICASO"
    echo "========================================================"
    echo
    printf "%-5s %-20s %-18s %-10s\n" \
        "ID" "NAME" "REMOTE IP" "STATUS"
    echo "--------------------------------------------------------"

    shopt -s nullglob

    for file in "$TUNNEL_DIR"/*.conf; do

        found=1

        id="$(basename "$file" .conf)"

        load_config "$id"

        local status
        status="$(get_tunnel_status "$id")"

        printf "%-5s %-20s %-18s %-10s\n" \
            "$ID" \
            "${NAME:0:20}" \
            "$REMOTE_PUBLIC_IP" \
            "$status"

    done

    shopt -u nullglob

    if (( found == 0 )); then
        echo "No tunnels configured."
    fi

    echo "--------------------------------------------------------"
    echo
}

# ------------------------------------------------------------
# Add tunnel
# ------------------------------------------------------------

add_tunnel() {

    echo
    echo "========================================================"
    echo "                   ADD NEW CONNECTION"
    echo "========================================================"
    echo

    local next_id
    next_id="$(get_next_id)"

    echo "Next available tunnel ID: $next_id"
    echo

    local role

    while true; do

        echo "Select server role:"
        echo
        echo "  1) Iran"
        echo "  2) Foreign"
        echo

        read -rp "Role [1-2]: " role

        case "$role" in
            1)
                role="iran"
                break
                ;;
            2)
                role="foreign"
                break
                ;;
            *)
                error "Invalid choice."
                ;;
        esac

    done

    local id="$next_id"

    if [[ "$role" == "foreign" ]]; then

        echo
        read -rp \
            "Enter the Tunnel ID assigned by Iran server [$next_id]: " custom_id

        if [[ -n "$custom_id" ]]; then
            id="$custom_id"
        fi

    fi

    if ! [[ "$id" =~ ^[0-9]+$ ]] || (( id < 1 )); then
        error "Invalid tunnel ID."
        return 1
    fi

    if id_exists "$id"; then
        error "Tunnel ID $id already exists."
        return 1
    fi

    local subnet

    subnet="$(calculate_subnet "$id")" || {
        error "Could not allocate subnet for ID $id."
        return 1
    }

    echo
    read -rp "Connection name (e.g. Germany-1): " name

    if [[ -z "$name" ]]; then
        name="Tunnel-$id"
    fi

    echo
    msg "Detecting local public IP..."

    local detected_ip=""

    detected_ip="$(detect_public_ip || true)"

    if valid_ipv4 "$detected_ip"; then
        echo "Detected public IP: $detected_ip"
    else
        warning "Could not automatically detect public IP."
    fi

    echo
    read -rp \
        "Local public IP [${detected_ip:-manual}]: " local_public

    if [[ -z "$local_public" ]]; then
        local_public="$detected_ip"
    fi

    if ! valid_ipv4 "$local_public"; then
        error "Invalid local public IP."
        return 1
    fi

    echo
    read -rp "Remote public IP: " remote_public

    if ! valid_ipv4 "$remote_public"; then
        error "Invalid remote public IP."
        return 1
    fi

    if [[ "$local_public" == "$remote_public" ]]; then
        error "Local and remote public IP cannot be the same."
        return 1
    fi

    if remote_ip_exists "$remote_public"; then

        warning "This remote IP is already used by another PICASO tunnel."

        read -rp "Continue anyway? [y/N]: " answer

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            return
        fi

    fi

    local local_tunnel
    local remote_tunnel

    local_tunnel="$(local_tunnel_ip "$subnet" "$role")"
    remote_tunnel="$(remote_tunnel_ip "$subnet" "$role")"

    local iface
    iface="$(interface_name "$id")"

    echo
    echo "========================================================"
    echo "                 CONNECTION PREVIEW"
    echo "========================================================"
    echo
    echo "ID               : $id"
    echo "Name             : $name"
    echo "Role             : $role"
    echo "Interface        : $iface"
    echo "Local Public IP  : $local_public"
    echo "Remote Public IP : $remote_public"
    echo "Subnet           : $subnet/30"
    echo "Local Tunnel IP  : $local_tunnel"
    echo "Remote Tunnel IP : $remote_tunnel"
    echo "MTU              : $MTU_DEFAULT"
    echo

    read -rp "Create this tunnel? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warning "Cancelled."
        return
    fi

    cat > "$(config_file "$id")" <<EOF
ID="$id"
NAME="$name"
ROLE="$role"

INTERFACE="$iface"

LOCAL_PUBLIC_IP="$local_public"
REMOTE_PUBLIC_IP="$remote_public"

SUBNET="$subnet"

LOCAL_TUNNEL_IP="$local_tunnel"
REMOTE_TUNNEL_IP="$remote_tunnel"

MTU="$MTU_DEFAULT"
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    chmod 600 "$(config_file "$id")"

    enable_forwarding

    if ! create_tunnel "$id"; then

        error "Tunnel creation failed."

        rm -f "$(config_file "$id")"

        return 1
    fi

    if [[ "$role" == "iran" ]]; then

        local new_next=$((id + 1))

        if (( new_next > $(get_next_id) )); then
            save_next_id "$new_next"
        fi

    fi

    success "Tunnel $id successfully created."

    log_msg "Tunnel $id ($name) added."

    echo
    echo "IMPORTANT:"
    echo "Create the matching tunnel on the other server using:"
    echo
    echo "  Tunnel ID       : $id"
    echo "  Remote Tunnel IP: $local_tunnel"
    echo
}

# ------------------------------------------------------------
# Manage tunnel menu
# ------------------------------------------------------------

manage_tunnel() {

    local id="$1"

    load_config "$id" || {
        error "Tunnel $id not found."
        return 1
    }

    while true; do

        clear

        local status
        status="$(get_tunnel_status "$id")"

        echo
        echo "========================================================"
        echo "             MANAGE: $INTERFACE"
        echo "========================================================"
        echo
        echo "Name            : $NAME"
        echo "Remote IP       : $REMOTE_PUBLIC_IP"
        echo "Tunnel IP       : $LOCAL_TUNNEL_IP"
        echo "Remote Tunnel   : $REMOTE_TUNNEL_IP"
        echo "Status          : $status"
        echo
        echo "--------------------------------------------------------"
        echo
        echo "  1) Start"
        echo "  2) Stop"
        echo "  3) Restart"
        echo "  4) Delete"
        echo "  5) Test connection"
        echo "  6) Show details"
        echo "  7) Show traffic"
        echo "  8) Back"
        echo

        read -rp "Select: " choice

        case "$choice" in

            1)
                start_tunnel "$id"
                pause_screen
                ;;

            2)
                stop_tunnel "$id"
                pause_screen
                ;;

            3)
                restart_tunnel "$id"
                pause_screen
                ;;

            4)
                delete_tunnel "$id"
                return
                ;;

            5)
                test_tunnel "$id"
                pause_screen
                ;;

            6)
                show_details "$id"
                pause_screen
                ;;

            7)
                show_traffic "$id"
                pause_screen
                ;;

            8)
                return
                ;;

            *)
                error "Invalid option."
                sleep 1
                ;;
        esac

    done
}

# ------------------------------------------------------------
# Select tunnel
# ------------------------------------------------------------

select_tunnel() {

    list_tunnels

    local id

    read -rp "Enter tunnel ID: " id

    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
        error "Invalid ID."
        return
    fi

    if ! id_exists "$id"; then
        error "Tunnel $id does not exist."
        return
    fi

    manage_tunnel "$id"
}

# ------------------------------------------------------------
# Check all tunnels
# ------------------------------------------------------------

check_all() {

    echo
    msg "Checking all tunnels..."
    echo

    local file
    local id

    shopt -s nullglob

    for file in "$TUNNEL_DIR"/*.conf; do

        id="$(basename "$file" .conf)"

        load_config "$id"

        local status
        status="$(get_tunnel_status "$id")"

        printf "%-20s : %-10s" "$INTERFACE" "$status"

        if [[ "$status" == "UP" ]]; then

            if ping -I "$INTERFACE" \
                -c 1 \
                -W 2 \
                "$REMOTE_TUNNEL_IP" \
                >/dev/null 2>&1; then

                echo -e "${GREEN}PING OK${RESET}"

            else

                echo -e "${RED}PING FAILED${RESET}"

            fi

        else
            echo
        fi

    done

    shopt -u nullglob

    echo
}

# ------------------------------------------------------------
# Repair / synchronize
# ------------------------------------------------------------

repair_all() {

    echo
    msg "Synchronizing configured tunnels..."
    echo

    local file
    local id

    shopt -s nullglob

    for file in "$TUNNEL_DIR"/*.conf; do

        id="$(basename "$file" .conf)"

        load_config "$id"

        if interface_exists "$INTERFACE"; then

            success "$INTERFACE already exists."

        else

            warning "$INTERFACE missing. Recreating..."

            if create_tunnel "$id"; then
                success "$INTERFACE restored."
            else
                error "Failed to restore $INTERFACE."
            fi

        fi

    done

    shopt -u nullglob

    echo
    log_msg "Repair/synchronize completed."

}

# ------------------------------------------------------------
# BBR
# ------------------------------------------------------------

install_bbr() {

    echo
    echo "========================================================"
    echo "                    BBR OPTIMIZATION"
    echo "========================================================"
    echo

    local kernel
    kernel="$(uname -r)"

    echo "Kernel: $kernel"
    echo

    local available

    available="$(sysctl -n net.ipv4.tcp_allowed_congestion_control 2>/dev/null || true)"

    echo "Available congestion control:"
    echo "  $available"
    echo

    if grep -qw bbr <<< "$available"; then

        success "BBR is supported by this kernel."

    else

        warning "BBR is not currently available."

        if modprobe tcp_bbr 2>/dev/null; then
            success "tcp_bbr module loaded."
        else
            error "Could not load tcp_bbr."
            error "Your kernel may not support BBR."
            return 1
        fi

    fi

    local now
    now="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

    echo "Current congestion control: ${now:-unknown}"
    echo

    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || {
        error "Failed to enable BBR."
        return 1
    }

    mkdir -p /etc/sysctl.d

    cat > /etc/sysctl.d/99-picaso-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl --system >/dev/null 2>&1 || true

    success "BBR enabled."

    echo
    echo "Current settings:"
    echo
    sysctl net.core.default_qdisc
    sysctl net.ipv4.tcp_congestion_control

    log_msg "BBR enabled."
}

# ------------------------------------------------------------
# Network optimization
# ------------------------------------------------------------

network_optimization() {

    echo
    echo "========================================================"
    echo "                 NETWORK OPTIMIZATION"
    echo "========================================================"
    echo

    mkdir -p /etc/sysctl.d

    cat > /etc/sysctl.d/99-picaso-network.conf <<EOF
# PICASO network optimization

net.ipv4.ip_forward = 1

net.core.default_qdisc = fq

net.ipv4.tcp_mtu_probing = 1

net.ipv4.tcp_fin_timeout = 15

net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

net.core.somaxconn = 4096

net.core.netdev_max_backlog = 16384

net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_syncookies = 1

net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

    sysctl --system >/dev/null 2>&1 || true

    success "Network optimization applied."

    log_msg "Network optimization applied."

    echo
}

# ------------------------------------------------------------
# Show optimization
# ------------------------------------------------------------

show_optimization() {

    echo
    echo "========================================================"
    echo "                 CURRENT SETTINGS"
    echo "========================================================"
    echo

    echo "Kernel:"
    uname -r

    echo
    echo "Congestion control:"
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true

    echo
    echo "Available congestion control:"
    sysctl net.ipv4.tcp_allowed_congestion_control 2>/dev/null || true

    echo
    echo "Default qdisc:"
    sysctl net.core.default_qdisc 2>/dev/null || true

    echo
    echo "IPv4 forwarding:"
    sysctl net.ipv4.ip_forward 2>/dev/null || true

    echo
    echo "TCP MTU probing:"
    sysctl net.ipv4.tcp_mtu_probing 2>/dev/null || true

    echo
}

# ------------------------------------------------------------
# Optimization menu
# ------------------------------------------------------------

optimization_menu() {

    while true; do

        clear

        echo
        echo "========================================================"
        echo "                SERVER OPTIMIZATION"
        echo "========================================================"
        echo
        echo "  1) Install / Enable BBR"
        echo "  2) Optimize TCP / Network"
        echo "  3) Enable IPv4 forwarding"
        echo "  4) Apply all recommended optimizations"
        echo "  5) Show current settings"
        echo "  6) Back"
        echo

        read -rp "Select: " choice

        case "$choice" in

            1)
                install_bbr
                pause_screen
                ;;

            2)
                network_optimization
                pause_screen
                ;;

            3)
                enable_forwarding
                pause_screen
                ;;

            4)
                install_bbr || true
                network_optimization
                enable_forwarding
                success "All recommended optimizations applied."
                pause_screen
                ;;

            5)
                show_optimization
                pause_screen
                ;;

            6)
                return
                ;;

            *)
                error "Invalid option."
                sleep 1
                ;;
        esac

    done
}

# ------------------------------------------------------------
# Logs
# ------------------------------------------------------------

show_logs() {

    echo
    echo "========================================================"
    echo "                     PICASO LOG"
    echo "========================================================"
    echo

    if [[ -f "$LOG_FILE" ]]; then
        tail -n 100 "$LOG_FILE"
    else
        echo "No log file."
    fi
}

live_logs() {

    touch "$LOG_FILE"

    tail -f "$LOG_FILE"
}

# ------------------------------------------------------------
# Restore service
# ------------------------------------------------------------

create_restore_service() {

    cat > "$RESTORE_BIN" <<'EOF'
#!/usr/bin/env bash

BASE_DIR="/etc/picaso"
TUNNEL_DIR="${BASE_DIR}/tunnels"

mkdir -p "$TUNNEL_DIR"

for file in "$TUNNEL_DIR"/*.conf; do

    [[ -f "$file" ]] || continue

    unset ID NAME ROLE INTERFACE
    unset LOCAL_PUBLIC_IP REMOTE_PUBLIC_IP
    unset SUBNET LOCAL_TUNNEL_IP REMOTE_TUNNEL_IP MTU

    # shellcheck disable=SC1090
    source "$file"

    if ip link show "$INTERFACE" >/dev/null 2>&1; then
        ip link set "$INTERFACE" up 2>/dev/null || true
        continue
    fi

    ip tunnel add "$INTERFACE" \
        mode gre \
        local "$LOCAL_PUBLIC_IP" \
        remote "$REMOTE_PUBLIC_IP" \
        ttl 255 2>/dev/null || continue

    ip link set "$INTERFACE" mtu "${MTU:-1476}" 2>/dev/null || true

    ip addr add "${LOCAL_TUNNEL_IP}/30" \
        dev "$INTERFACE" 2>/dev/null || true

    ip link set "$INTERFACE" up 2>/dev/null || true

done
EOF

    chmod +x "$RESTORE_BIN"

    cat > "$RESTORE_SERVICE" <<EOF
[Unit]
Description=PICASO GRE Restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RESTORE_BIN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable picaso-restore.service >/dev/null 2>&1

    success "Restore service installed."
}

# ------------------------------------------------------------
# Monitor service
# ------------------------------------------------------------

create_monitor_service() {

    cat > "$MONITOR_BIN" <<'EOF'
#!/usr/bin/env bash

BASE_DIR="/etc/picaso"
TUNNEL_DIR="${BASE_DIR}/tunnels"
LOG_FILE="/var/log/picaso.log"

declare -A LAST_STATE

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

while true; do

    shopt -s nullglob

    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -f "$file" ]] || continue

        unset ID NAME ROLE INTERFACE
        unset LOCAL_PUBLIC_IP REMOTE_PUBLIC_IP
        unset SUBNET LOCAL_TUNNEL_IP REMOTE_TUNNEL_IP MTU

        # shellcheck disable=SC1090
        source "$file"

        state="DOWN"

        if ip link show "$INTERFACE" >/dev/null 2>&1; then

            if ping -I "$INTERFACE" \
                -c 1 \
                -W 2 \
                "$REMOTE_TUNNEL_IP" \
                >/dev/null 2>&1; then

                state="UP"

            else

                state="DOWN"

            fi

        fi

        old="${LAST_STATE[$ID]:-UNKNOWN}"

        if [[ "$state" != "$old" ]]; then

            log_msg "Tunnel $ID ($INTERFACE) state changed: $old -> $state"

            LAST_STATE[$ID]="$state"

        fi

    done

    shopt -u nullglob

    sleep 30

done
EOF

    chmod +x "$MONITOR_BIN"

    cat > "$MONITOR_SERVICE" <<EOF
[Unit]
Description=PICASO GRE Monitor
After=network-online.target picaso-restore.service
Wants=network-online.target
Requires=picaso-restore.service

[Service]
Type=simple
ExecStart=$MONITOR_BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable picaso-monitor.service >/dev/null 2>&1
    systemctl restart picaso-monitor.service >/dev/null 2>&1 || true

    success "Monitor service installed."
}

# ------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------

uninstall_picaso() {

    clear

    echo
    echo "========================================================"
    echo "              COMPLETE PICASO UNINSTALL"
    echo "========================================================"
    echo

    warning "This will remove PICASO from this server."
    echo
    echo "It will remove:"
    echo
    echo "  - All PICASO GRE tunnels"
    echo "  - PICASO configurations"
    echo "  - Restore service"
    echo "  - Monitor service"
    echo "  - PICASO firewall rules"
    echo "  - PICASO logs"
    echo "  - PICASO command"
    echo

    read -rp "Are you sure? [yes/NO]: " confirm

    if [[ "$confirm" != "yes" ]]; then
        warning "Uninstall cancelled."
        return
    fi

    echo
    read -rp "Type DELETE to continue: " confirm2

    if [[ "$confirm2" != "DELETE" ]]; then
        warning "Uninstall cancelled."
        return
    fi

    echo
    msg "Stopping PICASO services..."

    systemctl disable --now picaso-monitor.service \
        >/dev/null 2>&1 || true

    systemctl disable --now picaso-restore.service \
        >/dev/null 2>&1 || true

    echo
    msg "Removing GRE tunnels..."

    local file
    local id

    shopt -s nullglob

    for file in "$TUNNEL_DIR"/*.conf; do

        id="$(basename "$file" .conf)"

        load_config "$id" || continue

        firewall_remove "$REMOTE_PUBLIC_IP" "$INTERFACE"

        if interface_exists "$INTERFACE"; then
            ip link delete "$INTERFACE" 2>/dev/null || true
        fi

        success "$INTERFACE removed."

    done

    shopt -u nullglob

    echo
    msg "Removing services..."

    rm -f "$RESTORE_SERVICE"
    rm -f "$MONITOR_SERVICE"

    rm -f "$RESTORE_BIN"
    rm -f "$MONITOR_BIN"

    systemctl daemon-reload

    echo
    msg "Removing configuration..."

    rm -rf "$BASE_DIR"

    rm -f "$LOG_FILE"

    echo
    msg "Removing optimization configuration..."

    rm -f /etc/sysctl.d/99-picaso-bbr.conf
    rm -f /etc/sysctl.d/99-picaso-network.conf
    rm -f /etc/sysctl.d/99-picaso-forwarding.conf

    systemctl daemon-reload >/dev/null 2>&1 || true

    echo
    success "PICASO has been completely removed."
    echo

    read -rp "Remove the picaso command now? [Y/n]: " remove_bin

    if [[ ! "$remove_bin" =~ ^[Nn]$ ]]; then

        rm -f "$BIN"

        success "PICASO command removed."

    fi

    echo
    echo "PICASO uninstall completed."
    echo

    exit 0
}

# ------------------------------------------------------------
# Install manager
# ------------------------------------------------------------

install_manager() {

    mkdir -p "$BASE_DIR"
    mkdir -p "$TUNNEL_DIR"

    touch "$LOG_FILE"

    create_restore_service
    create_monitor_service

    # Copy current script to manager command.
    #
    # When this file is being executed from a temporary location,
    # the manager section below is still copied.

    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        cp "${BASH_SOURCE[0]}" "$BIN"
        chmod +x "$BIN"
    fi

    success "PICASO manager installed."
}

# ------------------------------------------------------------
# Initial installation
# ------------------------------------------------------------

first_install() {

    require_root

    initialize_picaso

    install_dependencies

    install_manager

    enable_forwarding

    success "PICASO installation completed."

    log_msg "PICASO installed."

    echo
}

# ------------------------------------------------------------
# Main menu
# ------------------------------------------------------------

main_menu() {

    while true; do

        clear

        list_tunnels

        echo "  1) Add new connection"
        echo "  2) Manage a connection"
        echo "  3) Check all connections"
        echo "  4) Repair / Synchronize"
        echo "  5) Server optimization"
        echo "  6) Logs"
        echo "  7) Complete uninstall"
        echo "  0) Exit"
        echo

        read -rp "Select: " choice

        case "$choice" in

            1)
                add_tunnel
                pause_screen
                ;;

            2)
                select_tunnel
                ;;

            3)
                check_all
                pause_screen
                ;;

            4)
                repair_all
                pause_screen
                ;;

            5)
                optimization_menu
                ;;

            6)

                clear

                echo
                echo "  1) Show last 100 logs"
                echo "  2) Live logs"
                echo "  3) Back"
                echo

                read -rp "Select: " logchoice

                case "$logchoice" in

                    1)
                        show_logs
                        pause_screen
                        ;;

                    2)
                        live_logs
                        ;;

                    3)
                        ;;

                esac

                ;;

            7)
                uninstall_picaso
                ;;

            0)
                clear
                exit 0
                ;;

            *)
                error "Invalid option."
                sleep 1
                ;;

        esac

    done
}

# ------------------------------------------------------------
# Command line support
# ------------------------------------------------------------

command_mode() {

    local command="${1:-}"

    case "$command" in

        start)

            [[ -n "${2:-}" ]] || die "Usage: picaso start ID"

            start_tunnel "$2"

            ;;

        stop)

            [[ -n "${2:-}" ]] || die "Usage: picaso stop ID"

            stop_tunnel "$2"

            ;;

        restart)

            [[ -n "${2:-}" ]] || die "Usage: picaso restart ID"

            restart_tunnel "$2"

            ;;

        delete)

            [[ -n "${2:-}" ]] || die "Usage: picaso delete ID"

            delete_tunnel "$2"

            ;;

        test)

            [[ -n "${2:-}" ]] || die "Usage: picaso test ID"

            test_tunnel "$2"

            ;;

        details)

            [[ -n "${2:-}" ]] || die "Usage: picaso details ID"

            show_details "$2"

            ;;

        traffic)

            [[ -n "${2:-}" ]] || die "Usage: picaso traffic ID"

            show_traffic "$2"

            ;;

        status)

            list_tunnels

            ;;

        repair)

            repair_all

            ;;

        bbr)

            install_bbr

            ;;

        optimize)

            network_optimization

            ;;

        uninstall)

            uninstall_picaso

            ;;

        version)

            echo "PICASO GRE Manager v$VERSION"

            ;;

        help|-h|--help)

            echo
            echo "PICASO GRE Manager"
            echo
            echo "Usage:"
            echo
            echo "  picaso"
            echo "  picaso status"
            echo "  picaso start ID"
            echo "  picaso stop ID"
            echo "  picaso restart ID"
            echo "  picaso delete ID"
            echo "  picaso test ID"
            echo "  picaso details ID"
            echo "  picaso traffic ID"
            echo "  picaso repair"
            echo "  picaso bbr"
            echo "  picaso optimize"
            echo "  picaso uninstall"
            echo "  picaso version"
            echo

            ;;

        "")

            main_menu

            ;;

        *)

            error "Unknown command: $command"
            echo "Run: picaso help"
            exit 1
            ;;

    esac
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

require_root

if [[ ! -d "$BASE_DIR" ]]; then

    first_install

fi

initialize_picaso

if [[ "${1:-}" == "--install" ]]; then

    first_install
    exit 0

fi

command_mode "${1:-}" "${2:-}"
