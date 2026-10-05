#!/usr/bin/env bash

# ============================================================
# Vatan GRE Manager
# Multi GRE Tunnel Manager for Linux
#
# Supports:
#   - Iran -> Multiple Foreign servers
#   - Foreign -> Iran
#   - Multiple GRE interfaces
#   - Tunnel testing
#   - Traffic statistics
#   - Connection monitoring
#   - Persistent configuration
#   - Firewall configuration
# ============================================================

set -u

VERSION="1.0.0"

APP_NAME="Vatan GRE Manager"
CONFIG_DIR="/etc/vatan-gre"
LOG_FILE="/var/log/vatan-gre.log"
MONITOR_SCRIPT="/usr/local/bin/vatan-gre-monitor"
SERVICE_FILE="/etc/systemd/system/vatan-gre-monitor.service"

DEFAULT_NETWORK_BASE="132.168.30"
DEFAULT_MTU="1476"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    CYAN=$(tput setaf 6)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    RED=$(tput setaf 1)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    CYAN=""
    GREEN=""
    YELLOW=""
    RED=""
    BLUE=""
    BOLD=""
    RESET=""
fi

# ------------------------------------------------------------
# Basic functions
# ------------------------------------------------------------

pause() {
    echo
    read -r -p "Press Enter to continue..." _
}

info() {
    echo -e "${CYAN}[INFO]${RESET} $1"
}

success() {
    echo -e "${GREEN}[ OK ]${RESET} $1"
}

warning() {
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

die() {
    error "$1"
    exit 1
}

log() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Please run this script as root."
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

install_dependencies() {

    local REQUIRED=(
        ip
        ping
        iptables
        tcpdump
        systemctl
    )

    local MISSING=()

    for cmd in "${REQUIRED[@]}"; do
        if ! command_exists "$cmd"; then
            MISSING+=("$cmd")
        fi
    done

    if [ "${#MISSING[@]}" -eq 0 ]; then
        return
    fi

    echo
    warning "Some required commands are missing:"
    echo

    for cmd in "${MISSING[@]}"; do
        echo "  - $cmd"
    done

    echo

    if command_exists apt-get; then

        read -r -p "Install required packages using apt? [Y/n]: " ANSWER
        ANSWER=${ANSWER:-Y}

        if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
            apt-get update
            apt-get install -y iproute2 iputils-ping iptables tcpdump
        else
            die "Required packages are missing."
        fi

    elif command_exists dnf; then

        read -r -p "Install required packages using dnf? [Y/n]: " ANSWER
        ANSWER=${ANSWER:-Y}

        if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
            dnf install -y iproute iputils iptables tcpdump
        else
            die "Required packages are missing."
        fi

    elif command_exists yum; then

        read -r -p "Install required packages using yum? [Y/n]: " ANSWER
        ANSWER=${ANSWER:-Y}

        if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
            yum install -y iproute iputils iptables tcpdump
        else
            die "Required packages are missing."
        fi

    else
        die "Could not detect a supported package manager."
    fi
}

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

prepare_environment() {

    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"

    chmod 700 "$CONFIG_DIR"
    chmod 600 "$LOG_FILE"

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    cat > /etc/sysctl.d/99-vatan-gre.conf <<EOF
net.ipv4.ip_forward=1
EOF

    sysctl --system >/dev/null 2>&1 || true
}

# ------------------------------------------------------------
# Public IP detection
# ------------------------------------------------------------

detect_public_ip() {

    local IP=""

    if command_exists curl; then
        IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi

    if [ -z "$IP" ] && command_exists wget; then
        IP=$(wget -qO- -4 --timeout=5 https://api.ipify.org 2>/dev/null || true)
    fi

    echo "$IP"
}

ask_public_ip() {

    local LABEL="$1"
    local IP=""

    while true; do

        echo
        read -r -p "$LABEL public IP [Enter = auto detect]: " IP

        if [ -z "$IP" ]; then
            IP=$(detect_public_ip)

            if [ -n "$IP" ]; then
                echo
                success "Detected public IP: $IP"
                echo
                break
            else
                error "Could not detect public IP."
                continue
            fi
        fi

        if [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        else
            error "Invalid IPv4 address."
        fi

    done

    echo "$IP"
}

# ------------------------------------------------------------
# Tunnel network
# ------------------------------------------------------------

get_interface() {
    echo "vatan-gre$1"
}

get_network() {
    local ID="$1"
    local THIRD=$((29 + ID))

    echo "132.168.${THIRD}.0/30"
}

get_iran_tunnel_ip() {
    local ID="$1"
    local THIRD=$((29 + ID))

    echo "132.168.${THIRD}.2"
}

get_foreign_tunnel_ip() {
    local ID="$1"
    local THIRD=$((29 + ID))

    echo "132.168.${THIRD}.1"
}

# ------------------------------------------------------------
# Validate tunnel ID
# ------------------------------------------------------------

valid_tunnel_id() {

    local ID="$1"

    if ! [[ "$ID" =~ ^[1-9][0-9]*$ ]]; then
        return 1
    fi

    if [ "$ID" -gt 220 ]; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Existing tunnel
# ------------------------------------------------------------

tunnel_exists() {

    local ID="$1"
    local IFACE

    IFACE=$(get_interface "$ID")

    if ip link show "$IFACE" >/dev/null 2>&1; then
        return 0
    fi

    if [ -f "$CONFIG_DIR/$IFACE.conf" ]; then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

configure_firewall() {

    local REMOTE_IP="$1"
    local IFACE="$2"

    # GRE protocol = 47

    if ! iptables -C INPUT -p 47 -s "$REMOTE_IP" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p 47 -s "$REMOTE_IP" -j ACCEPT
    fi

    if ! iptables -C INPUT -i "$IFACE" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -i "$IFACE" -j ACCEPT
    fi

    if ! iptables -C OUTPUT -o "$IFACE" -j ACCEPT 2>/dev/null; then
        iptables -I OUTPUT -o "$IFACE" -j ACCEPT
    fi

    if ! iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null; then
        iptables -I FORWARD -i "$IFACE" -j ACCEPT
    fi

    if ! iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null; then
        iptables -I FORWARD -o "$IFACE" -j ACCEPT
    fi

    log "Firewall configured for $IFACE / $REMOTE_IP"
}

# ------------------------------------------------------------
# Save configuration
# ------------------------------------------------------------

save_config() {

    local ID="$1"
    local ROLE="$2"
    local LOCAL_IP="$3"
    local REMOTE_IP="$4"
    local IFACE="$5"
    local LOCAL_TUNNEL="$6"
    local REMOTE_TUNNEL="$7"
    local NETWORK="$8"
    local MTU="$9"

    cat > "$CONFIG_DIR/$IFACE.conf" <<EOF
ID="$ID"
ROLE="$ROLE"
LOCAL_IP="$LOCAL_IP"
REMOTE_IP="$REMOTE_IP"
INTERFACE="$IFACE"
LOCAL_TUNNEL_IP="$LOCAL_TUNNEL"
REMOTE_TUNNEL_IP="$REMOTE_TUNNEL"
NETWORK="$NETWORK"
MTU="$MTU"
EOF

    chmod 600 "$CONFIG_DIR/$IFACE.conf"
}

# ------------------------------------------------------------
# Create tunnel
# ------------------------------------------------------------

create_tunnel() {

    local ROLE="$1"

    echo
    echo "============================================================"
    echo "                    CREATE GRE TUNNEL"
    echo "============================================================"
    echo

    local ID=""

    while true; do

        read -r -p "Tunnel ID (1-220): " ID

        if valid_tunnel_id "$ID"; then
            break
        fi

        error "Invalid tunnel ID."
    done

    local IFACE
    IFACE=$(get_interface "$ID")

    if tunnel_exists "$ID"; then

        warning "$IFACE already exists."

        read -r -p "Replace existing tunnel? [y/N]: " ANSWER

        if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
            return
        fi

        delete_tunnel "$ID"
    fi

    local LOCAL_IP
    local REMOTE_IP

    if [ "$ROLE" = "IRAN" ]; then

        LOCAL_IP=$(ask_public_ip "Iran")

        echo
        read -r -p "Foreign server public IP: " REMOTE_IP

    else

        read -r -p "Iran server public IP: " REMOTE_IP

        LOCAL_IP=$(ask_public_ip "Foreign")
    fi

    if [ -z "$REMOTE_IP" ]; then
        error "Remote IP cannot be empty."
        return
    fi

    local NETWORK
    local LOCAL_TUNNEL
    local REMOTE_TUNNEL

    NETWORK=$(get_network "$ID")

    if [ "$ROLE" = "IRAN" ]; then
        LOCAL_TUNNEL=$(get_iran_tunnel_ip "$ID")
        REMOTE_TUNNEL=$(get_foreign_tunnel_ip "$ID")
    else
        LOCAL_TUNNEL=$(get_foreign_tunnel_ip "$ID")
        REMOTE_TUNNEL=$(get_iran_tunnel_ip "$ID")
    fi

    echo
    echo "------------------------------------------------------------"
    echo "Tunnel configuration"
    echo "------------------------------------------------------------"
    echo
    echo "Role          : $ROLE"
    echo "Interface     : $IFACE"
    echo "Local public  : $LOCAL_IP"
    echo "Remote public : $REMOTE_IP"
    echo "Network       : $NETWORK"
    echo "Local tunnel  : $LOCAL_TUNNEL"
    echo "Remote tunnel : $REMOTE_TUNNEL"
    echo "MTU           : $DEFAULT_MTU"
    echo

    read -r -p "Create this tunnel? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warning "Cancelled."
        return
    fi

    echo
    info "Creating $IFACE..."

    ip tunnel add "$IFACE" \
        mode gre \
        local "$LOCAL_IP" \
        remote "$REMOTE_IP" \
        ttl 255

    if [ $? -ne 0 ]; then
        error "Failed to create GRE interface."
        return
    fi

    ip link set "$IFACE" mtu "$DEFAULT_MTU"

    ip addr add "$LOCAL_TUNNEL/30" dev "$IFACE"

    ip link set "$IFACE" up

    configure_firewall "$REMOTE_IP" "$IFACE"

    save_config \
        "$ID" \
        "$ROLE" \
        "$LOCAL_IP" \
        "$REMOTE_IP" \
        "$IFACE" \
        "$LOCAL_TUNNEL" \
        "$REMOTE_TUNNEL" \
        "$NETWORK" \
        "$DEFAULT_MTU"

    log "CREATED $IFACE | $LOCAL_IP -> $REMOTE_IP | $LOCAL_TUNNEL -> $REMOTE_TUNNEL"

    echo
    success "$IFACE created successfully."

    echo
    info "Testing tunnel..."

    if ping -I "$IFACE" -c 3 -W 2 "$REMOTE_TUNNEL" >/dev/null 2>&1; then
        success "Tunnel connectivity: UP"
    else
        warning "Tunnel created, but remote tunnel IP is not responding."
        warning "Check the configuration on the other server."
    fi

    echo
}

# ------------------------------------------------------------
# Delete tunnel
# ------------------------------------------------------------

delete_tunnel() {

    local ID="$1"
    local IFACE

    IFACE=$(get_interface "$ID")

    if ! tunnel_exists "$ID"; then
        error "$IFACE does not exist."
        return
    fi

    echo
    warning "Deleting $IFACE..."

    if ip link show "$IFACE" >/dev/null 2>&1; then
        ip link set "$IFACE" down 2>/dev/null || true
        ip tunnel del "$IFACE" 2>/dev/null || true
    fi

    rm -f "$CONFIG_DIR/$IFACE.conf"

    log "DELETED $IFACE"

    success "$IFACE deleted."
}

# ------------------------------------------------------------
# List tunnels
# ------------------------------------------------------------

list_tunnels() {

    echo
    echo "============================================================"
    echo "                    CONFIGURED TUNNELS"
    echo "============================================================"
    echo

    local FOUND=0
    local FILE

    shopt -s nullglob

    for FILE in "$CONFIG_DIR"/vatan-gre*.conf; do

        FOUND=1

        unset ID ROLE LOCAL_IP REMOTE_IP INTERFACE
        unset LOCAL_TUNNEL_IP REMOTE_TUNNEL_IP NETWORK MTU

        source "$FILE"

        echo "------------------------------------------------------------"
        echo "Tunnel ID     : $ID"
        echo "Interface     : $INTERFACE"
        echo "Role          : $ROLE"
        echo "Local public  : $LOCAL_IP"
        echo "Remote public : $REMOTE_IP"
        echo "Local tunnel  : $LOCAL_TUNNEL_IP"
        echo "Remote tunnel : $REMOTE_TUNNEL_IP"
        echo "Network       : $NETWORK"

        if ip link show "$INTERFACE" >/dev/null 2>&1; then
            success "Interface: UP"
        else
            error "Interface: DOWN / MISSING"
        fi

        echo
    done

    if [ "$FOUND" -eq 0 ]; then
        warning "No tunnels configured."
    fi
}

# ------------------------------------------------------------
# Tunnel status
# ------------------------------------------------------------

show_status() {

    echo
    echo "============================================================"
    echo "                    GRE TUNNEL STATUS"
    echo "============================================================"
    echo

    local FILE
    local FOUND=0

    shopt -s nullglob

    for FILE in "$CONFIG_DIR"/vatan-gre*.conf; do

        FOUND=1

        unset ID ROLE LOCAL_IP REMOTE_IP INTERFACE
        unset LOCAL_TUNNEL_IP REMOTE_TUNNEL_IP NETWORK MTU

        source "$FILE"

        echo -n "$INTERFACE"

        if ip link show "$INTERFACE" >/dev/null 2>&1; then

            if ping -I "$INTERFACE" -c 1 -W 2 "$REMOTE_TUNNEL_IP" >/dev/null 2>&1; then
                echo -e " : ${GREEN}UP${RESET}   | $REMOTE_TUNNEL_IP"
            else
                echo -e " : ${RED}DOWN${RESET} | $REMOTE_TUNNEL_IP"
            fi

        else
            echo -e " : ${RED}MISSING${RESET}"
        fi
    done

    if [ "$FOUND" -eq 0 ]; then
        warning "No tunnels configured."
    fi

    echo
}

# ------------------------------------------------------------
# Detailed test
# ------------------------------------------------------------

test_tunnel() {

    local ID="$1"
    local IFACE

    IFACE=$(get_interface "$ID")

    if [ ! -f "$CONFIG_DIR/$IFACE.conf" ]; then
        error "Tunnel $ID is not configured."
        return
    fi

    source "$CONFIG_DIR/$IFACE.conf"

    echo
    echo "============================================================"
    echo "                    TUNNEL DIAGNOSTICS"
    echo "============================================================"
    echo

    echo "[1/5] Interface"

    if ip link show "$IFACE" >/dev/null 2>&1; then
        success "$IFACE exists"
    else
        error "$IFACE does not exist"
        return
    fi

    echo
    echo "[2/5] GRE configuration"

    ip tunnel show "$IFACE"

    echo
    echo "[3/5] IP configuration"

    ip addr show dev "$IFACE"

    echo
    echo "[4/5] Connectivity"

    if ping -I "$IFACE" -c 4 -W 2 "$REMOTE_TUNNEL_IP"; then
        success "Tunnel connectivity is UP"
    else
        error "Tunnel connectivity is DOWN"
    fi

    echo
    echo "[5/5] Traffic statistics"

    ip -s link show "$IFACE"

    echo
}

# ------------------------------------------------------------
# Logs
# ------------------------------------------------------------

show_logs() {

    echo
    echo "============================================================"
    echo "                    LIVE GRE LOG"
    echo "============================================================"
    echo
    echo "Press CTRL+C to stop."
    echo

    touch "$LOG_FILE"

    tail -f "$LOG_FILE"
}

# ------------------------------------------------------------
# Packet capture
# ------------------------------------------------------------

capture_gre() {

    echo
    echo "============================================================"
    echo "                    GRE PACKET CAPTURE"
    echo "============================================================"
    echo
    echo "Protocol GRE = IP protocol 47"
    echo "Press CTRL+C to stop."
    echo

    tcpdump -ni any 'ip proto 47'
}

# ------------------------------------------------------------
# Monitor
# ------------------------------------------------------------

install_monitor() {

    cat > "$MONITOR_SCRIPT" <<'EOF'
#!/usr/bin/env bash

CONFIG_DIR="/etc/vatan-gre"
LOG_FILE="/var/log/vatan-gre.log"

mkdir -p "$CONFIG_DIR"
touch "$LOG_FILE"

declare -A LAST_STATE

while true; do

    for FILE in "$CONFIG_DIR"/vatan-gre*.conf; do

        [ -f "$FILE" ] || continue

        unset INTERFACE REMOTE_TUNNEL_IP
        source "$FILE"

        if ! ip link show "$INTERFACE" >/dev/null 2>&1; then

            STATE="MISSING"

        elif ping -I "$INTERFACE" -c 1 -W 2 "$REMOTE_TUNNEL_IP" >/dev/null 2>&1; then

            STATE="UP"

        else

            STATE="DOWN"

        fi

        OLD="${LAST_STATE[$INTERFACE]:-UNKNOWN}"

        if [ "$STATE" != "$OLD" ]; then

            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $INTERFACE $OLD -> $STATE" >> "$LOG_FILE"

            LAST_STATE[$INTERFACE]="$STATE"
        fi

    done

    sleep 10

done
EOF

    chmod +x "$MONITOR_SCRIPT"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Vatan GRE Tunnel Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$MONITOR_SCRIPT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vatan-gre-monitor.service >/dev/null 2>&1
    systemctl restart vatan-gre-monitor.service

    success "GRE monitor installed and enabled."
}

# ------------------------------------------------------------
# Firewall status
# ------------------------------------------------------------

show_firewall() {

    echo
    echo "============================================================"
    echo "                    GRE FIREWALL RULES"
    echo "============================================================"
    echo

    echo "GRE protocol rules:"
    iptables -L INPUT -n -v --line-numbers | grep -E '47|vatan' || true

    echo
    echo "FORWARD rules:"
    iptables -L FORWARD -n -v --line-numbers | head -30

    echo
}

# ------------------------------------------------------------
# Main menu
# ------------------------------------------------------------

main_menu() {

    while true; do

        clear

        echo -e "${CYAN}${BOLD}"
        echo "============================================================"
        echo "                 VATAN GRE MANAGER"
        echo "                       v$VERSION"
        echo "============================================================"
        echo -e "${RESET}"

        echo "  1) Create GRE tunnel"
        echo "  2) Delete GRE tunnel"
        echo "  3) List configured tunnels"
        echo "  4) Tunnel status"
        echo "  5) Test / Diagnose tunnel"
        echo "  6) Live logs"
        echo "  7) Capture GRE packets"
        echo "  8) Firewall status"
        echo "  9) Install / Repair monitor"
        echo " 10) Enable IP forwarding"
        echo "  0) Exit"
        echo

        read -r -p "Select an option [0-10]: " OPTION

        case "$OPTION" in

            1)

                echo
                echo "Select server role:"
                echo
                echo "  1) Iran"
                echo "  2) Foreign"
                echo

                read -r -p "Select [1-2]: " ROLE

                case "$ROLE" in

                    1)
                        create_tunnel "IRAN"
                        ;;

                    2)
                        create_tunnel "FOREIGN"
                        ;;

                    *)
                        error "Invalid role."
                        ;;
                esac

                pause
                ;;

            2)

                echo
                read -r -p "Tunnel ID to delete: " ID

                if valid_tunnel_id "$ID"; then
                    delete_tunnel "$ID"
                else
                    error "Invalid tunnel ID."
                fi

                pause
                ;;

            3)

                list_tunnels
                pause
                ;;

            4)

                show_status
                pause
                ;;

            5)

                read -r -p "Tunnel ID: " ID

                if valid_tunnel_id "$ID"; then
                    test_tunnel "$ID"
                else
                    error "Invalid tunnel ID."
                fi

                pause
                ;;

            6)

                show_logs
                ;;

            7)

                capture_gre
                ;;

            8)

                show_firewall
                pause
                ;;

            9)

                install_monitor
                pause
                ;;

            10)

                sysctl -w net.ipv4.ip_forward=1 >/dev/null

                cat > /etc/sysctl.d/99-vatan-gre.conf <<EOF
net.ipv4.ip_forward=1
EOF

                sysctl --system >/dev/null 2>&1 || true

                success "IPv4 forwarding enabled."

                pause
                ;;

            0)

                echo
                echo "Goodbye."
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
# Start
# ------------------------------------------------------------

require_root

mkdir -p "$CONFIG_DIR"
touch "$LOG_FILE"

install_dependencies
prepare_environment

if [ ! -x "$MONITOR_SCRIPT" ]; then
    install_monitor
fi

main_menu