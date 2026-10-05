#!/usr/bin/env bash

# ============================================================
# PICASO
# Multi GRE Tunnel Manager
# ============================================================
#
# Architecture:
#
# Client
#   |
#   | Public Iran IP : Port
#   v
# Iran Server
#   |
#   | DNAT
#   v
# GRE Tunnel
#   |
#   v
# Foreign Server
#   |
#   v
# Xray / Service
#
# GRE:
#   Iran    = .2
#   Foreign = .1
#
# Example:
#   Client -> 45.135.242.173:443
#            |
#            v
#   132.168.30.1:443
#            |
#            v
#   Foreign Xray
#
# ============================================================

set -Eeuo pipefail

VERSION="3.0.0"

BASE_DIR="/etc/picaso"
TUNNEL_DIR="${BASE_DIR}/tunnels"
PORT_DIR="${BASE_DIR}/ports"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/picaso.log"

BIN="/usr/local/bin/picaso"
RESTORE="/usr/local/sbin/picaso-restore"
MONITOR="/usr/local/sbin/picaso-monitor"

RESTORE_SERVICE="picaso-restore.service"
MONITOR_SERVICE="picaso-monitor.service"

MANAGER_CONF="${BASE_DIR}/manager.conf"
STATE_FILE="${BASE_DIR}/next_id"

IPTABLES="iptables"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'

# ============================================================
# BASIC
# ============================================================

log() {
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

info() {
    echo -e "${CYAN}[INFO]${RESET} $*"
}

ok() {
    echo -e "${GREEN}[ OK ]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

die() {
    error "$*"
    exit 1
}

pause() {
    echo
    read -r -p "Press Enter to continue..." _
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Run this script as root."
}

require_commands() {
    local commands=(
        ip
        iptables
        systemctl
        awk
        sed
        grep
        ping
    )

    for cmd in "${commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

# ============================================================
# DIRECTORY / CONFIG
# ============================================================

init_dirs() {
    mkdir -p "$BASE_DIR"
    mkdir -p "$TUNNEL_DIR"
    mkdir -p "$PORT_DIR"

    touch "$LOG_FILE"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "1" > "$STATE_FILE"
    fi

    if [[ ! -f "$MANAGER_CONF" ]]; then
        cat > "$MANAGER_CONF" <<EOF
PICASO_VERSION=${VERSION}
DEFAULT_SUBNET_BASE=10.250
EOF
    fi
}

# ============================================================
# VALIDATION
# ============================================================

valid_ipv4() {
    local ip="$1"
    local IFS=.

    read -r a b c d <<< "$ip" || return 1

    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    [[ "$b" =~ ^[0-9]+$ ]] || return 1
    [[ "$c" =~ ^[0-9]+$ ]] || return 1
    [[ "$d" =~ ^[0-9]+$ ]] || return 1

    ((a <= 255 && b <= 255 && c <= 255 && d <= 255))
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ((p >= 1 && p <= 65535))
}

valid_proto() {
    case "$1" in
        tcp|udp) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# PUBLIC IP
# ============================================================

detect_public_ip() {

    local ip=""

    ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{
            for(i=1;i<=NF;i++)
                if($i=="src") {
                    print $(i+1)
                    exit
                }
        }' || true)

    if valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    ip=$(ip -4 addr show scope global |
        awk '/inet / {
            sub("/.*","",$2)
            print $2
            exit
        }' || true)

    valid_ipv4 "$ip" && echo "$ip"
}

# ============================================================
# ID MANAGEMENT
# ============================================================

get_next_id() {

    local id

    id=$(cat "$STATE_FILE" 2>/dev/null || echo 1)

    [[ "$id" =~ ^[0-9]+$ ]] || id=1

    echo $((id + 1)) > "$STATE_FILE"

    echo "$id"
}

tunnel_exists() {
    [[ -f "${TUNNEL_DIR}/$1.conf" ]]
}

# ============================================================
# TUNNEL CONFIG
# ============================================================

save_tunnel() {
    local id="$1"
    local role="$2"
    local local_public="$3"
    local remote_public="$4"
    local iface="$5"
    local local_tun="$6"
    local remote_tun="$7"
    local subnet="$8"
    local mtu="$9"

    cat > "${TUNNEL_DIR}/${id}.conf" <<EOF
ID=${id}
ROLE=${role}
LOCAL_PUBLIC=${local_public}
REMOTE_PUBLIC=${remote_public}
INTERFACE=${iface}
LOCAL_TUNNEL=${local_tun}
REMOTE_TUNNEL=${remote_tun}
SUBNET=${subnet}
MTU=${mtu}
ENABLED=1
EOF
}

load_tunnel() {
    local id="$1"
    local file="${TUNNEL_DIR}/${id}.conf"

    [[ -f "$file" ]] || return 1

    # shellcheck disable=SC1090
    source "$file"
}

# ============================================================
# SUBNET ALLOCATION
# ============================================================

get_subnet_for_id() {

    local id="$1"

    local index=$((id - 1))
    local second=$((index / 64))
    local block=$((index % 64))

    echo "10.250.${second}.$((block * 4))/30"
}

subnet_local_ip() {
    local subnet="$1"

    echo "$subnet" |
        awk -F'[./]' '{print $1"."$2"."$3"."($4+1)}'
}

subnet_remote_ip() {
    local subnet="$1"

    echo "$subnet" |
        awk -F'[./]' '{print $1"."$2"."$3"."($4+2)}'
}

# ============================================================
# INTERFACE
# ============================================================

interface_exists() {
    ip link show "$1" >/dev/null 2>&1
}

delete_interface() {
    local iface="$1"

    if interface_exists "$iface"; then
        ip link set "$iface" down 2>/dev/null || true
        ip tunnel del "$iface" 2>/dev/null || true
    fi
}

# ============================================================
# GRE FIREWALL
# ============================================================

add_gre_firewall() {

    local remote_public="$1"
    local iface="$2"

    iptables -C INPUT \
        -p 47 \
        -s "$remote_public" \
        -j ACCEPT \
        -m comment \
        --comment "PICASO GRE ${iface}" \
        2>/dev/null ||
    iptables -I INPUT 1 \
        -p 47 \
        -s "$remote_public" \
        -j ACCEPT \
        -m comment \
        --comment "PICASO GRE ${iface}"

    iptables -C INPUT \
        -i "$iface" \
        -j ACCEPT \
        -m comment \
        --comment "PICASO TUNNEL ${iface}" \
        2>/dev/null ||
    iptables -I INPUT 1 \
        -i "$iface" \
        -j ACCEPT \
        -m comment \
        --comment "PICASO TUNNEL ${iface}"
}

remove_gre_firewall() {

    local remote_public="$1"
    local iface="$2"

    while iptables -C INPUT \
        -p 47 \
        -s "$remote_public" \
        -j ACCEPT \
        -m comment \
        --comment "PICASO GRE ${iface}" \
        2>/dev/null; do

        iptables -D INPUT \
            -p 47 \
            -s "$remote_public" \
            -j ACCEPT \
            -m comment \
            --comment "PICASO GRE ${iface}" || true
    done

    while iptables -C INPUT \
        -i "$iface" \
        -j ACCEPT \
        -m comment \
        --comment "PICASO TUNNEL ${iface}" \
        2>/dev/null; do

        iptables -D INPUT \
            -i "$iface" \
            -j ACCEPT \
            -m comment \
            --comment "PICASO TUNNEL ${iface}" || true
    done
}

# ============================================================
# CREATE GRE
# ============================================================

create_gre() {

    local id="$1"

    load_tunnel "$id" || die "Tunnel $id not found."

    info "Creating ${INTERFACE}..."

    if interface_exists "$INTERFACE"; then

        local current

        current=$(ip -d link show "$INTERFACE" 2>/dev/null || true)

        if ! grep -q "remote ${REMOTE_PUBLIC}" <<< "$current" ||
           ! grep -q "local ${LOCAL_PUBLIC}" <<< "$current"; then

            warn "Existing ${INTERFACE} does not match configuration."
            ip link set "$INTERFACE" down 2>/dev/null || true
            ip tunnel del "$INTERFACE" 2>/dev/null || true

        else
            info "${INTERFACE} already exists."
        fi
    fi

    if ! interface_exists "$INTERFACE"; then

        ip tunnel add "$INTERFACE" \
            mode gre \
            local "$LOCAL_PUBLIC" \
            remote "$REMOTE_PUBLIC" \
            ttl 255

    fi

    ip link set "$INTERFACE" mtu "$MTU"
    ip link set "$INTERFACE" up

    if ! ip addr show dev "$INTERFACE" |
        grep -q "inet ${LOCAL_TUNNEL}/"; then

        ip addr add "${LOCAL_TUNNEL}/30" dev "$INTERFACE"
    fi

    add_gre_firewall "$REMOTE_PUBLIC" "$INTERFACE"

    ok "${INTERFACE} is configured."

    log "Tunnel ${id} GRE configured: ${LOCAL_PUBLIC} -> ${REMOTE_PUBLIC}"
}

# ============================================================
# FORWARDING
# ============================================================

enable_forwarding() {

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    cat > /etc/sysctl.d/99-picaso-forwarding.conf <<EOF
net.ipv4.ip_forward=1
EOF

    sysctl --system >/dev/null 2>&1 || true
}

# ============================================================
# PORT RULES
# ============================================================

add_port_rule() {

    local id="$1"
    local proto="$2"
    local public_port="$3"
    local destination_port="$4"

    valid_proto "$proto" || die "Invalid protocol."
    valid_port "$public_port" || die "Invalid public port."
    valid_port "$destination_port" || die "Invalid destination port."

    local file="${PORT_DIR}/${id}.rules"

    touch "$file"

    if grep -q "^${proto}|${public_port}|${destination_port}$" "$file"; then
        warn "This forwarding rule already exists."
        return 0
    fi

    echo "${proto}|${public_port}|${destination_port}" >> "$file"

    ok "Forwarding added: ${proto} ${public_port} -> ${destination_port}"

    apply_port_rules "$id"
}

remove_port_rule() {

    local id="$1"
    local proto="$2"
    local public_port="$3"
    local destination_port="$4"

    local file="${PORT_DIR}/${id}.rules"

    [[ -f "$file" ]] || return 0

    sed -i \
        "\#^${proto}|${public_port}|${destination_port}$#d" \
        "$file"

    clear_port_rules "$id"
    apply_port_rules "$id"
}

# ============================================================
# PORT FIREWALL RULES
# ============================================================

clear_port_rules() {

    local id="$1"

    load_tunnel "$id" || return 0

    local file="${PORT_DIR}/${id}.rules"

    [[ -f "$file" ]] || return 0

    while IFS='|' read -r proto public_port destination_port; do

        [[ -z "$proto" ]] && continue
        [[ "$proto" =~ ^# ]] && continue

        # PREROUTING DNAT
        while iptables -t nat -C PREROUTING \
            -i "$(ip route show default | awk 'NR==1{print $5}')" \
            -p "$proto" \
            -d "$LOCAL_PUBLIC" \
            --dport "$public_port" \
            -j DNAT \
            --to-destination "${REMOTE_TUNNEL}:${destination_port}" \
            -m comment \
            --comment "PICASO PF ${id}" \
            2>/dev/null; do

            iptables -t nat -D PREROUTING \
                -i "$(ip route show default | awk 'NR==1{print $5}')" \
                -p "$proto" \
                -d "$LOCAL_PUBLIC" \
                --dport "$public_port" \
                -j DNAT \
                --to-destination "${REMOTE_TUNNEL}:${destination_port}" \
                -m comment \
                --comment "PICASO PF ${id}" || true
        done

        # FORWARD incoming
        while iptables -C FORWARD \
            -i "$(ip route show default | awk 'NR==1{print $5}')" \
            -o "$INTERFACE" \
            -p "$proto" \
            -d "$REMOTE_TUNNEL" \
            --dport "$destination_port" \
            -m conntrack \
            --ctstate NEW,ESTABLISHED,RELATED \
            -j ACCEPT \
            -m comment \
            --comment "PICASO PF ${id}" \
            2>/dev/null; do

            iptables -D FORWARD \
                -i "$(ip route show default | awk 'NR==1{print $5}')" \
                -o "$INTERFACE" \
                -p "$proto" \
                -d "$REMOTE_TUNNEL" \
                --dport "$destination_port" \
                -m conntrack \
                --ctstate NEW,ESTABLISHED,RELATED \
                -j ACCEPT \
                -m comment \
                --comment "PICASO PF ${id}" || true
        done

        # FORWARD return
        while iptables -C FORWARD \
            -i "$INTERFACE" \
            -o "$(ip route show default | awk 'NR==1{print $5}')" \
            -p "$proto" \
            -s "$REMOTE_TUNNEL" \
            --sport "$destination_port" \
            -m conntrack \
            --ctstate ESTABLISHED,RELATED \
            -j ACCEPT \
            -m comment \
            --comment "PICASO PF ${id}" \
            2>/dev/null; do

            iptables -D FORWARD \
                -i "$INTERFACE" \
                -o "$(ip route show default | awk 'NR==1{print $5}')" \
                -p "$proto" \
                -s "$REMOTE_TUNNEL" \
                --sport "$destination_port" \
                -m conntrack \
                --ctstate ESTABLISHED,RELATED \
                -j ACCEPT \
                -m comment \
                --comment "PICASO PF ${id}" || true
        done

        # SNAT / MASQUERADE
        while iptables -t nat -C POSTROUTING \
            -o "$INTERFACE" \
            -p "$proto" \
            -d "$REMOTE_TUNNEL" \
            --dport "$destination_port" \
            -j MASQUERADE \
            -m comment \
            --comment "PICASO PF ${id}" \
            2>/dev/null; do

            iptables -t nat -D POSTROUTING \
                -o "$INTERFACE" \
                -p "$proto" \
                -d "$REMOTE_TUNNEL" \
                --dport "$destination_port" \
                -j MASQUERADE \
                -m comment \
                --comment "PICASO PF ${id}" || true
        done

    done < "$file"
}

apply_port_rules() {

    local id="$1"

    load_tunnel "$id" || return 0

    [[ "$ROLE" == "IRAN" ]] || return 0

    local file="${PORT_DIR}/${id}.rules"

    [[ -f "$file" ]] || return 0

    enable_forwarding

    local wan
    wan=$(ip route show default |
        awk 'NR==1{print $5}')

    [[ -n "$wan" ]] || die "Could not detect WAN interface."

    while IFS='|' read -r proto public_port destination_port; do

        [[ -z "$proto" ]] && continue
        [[ "$proto" =~ ^# ]] && continue

        # ----------------------------------------------------
        # CLIENT -> IRAN PUBLIC IP -> FOREIGN TUNNEL IP
        # ----------------------------------------------------

        iptables -t nat -C PREROUTING \
            -i "$wan" \
            -p "$proto" \
            -d "$LOCAL_PUBLIC" \
            --dport "$public_port" \
            -j DNAT \
            --to-destination "${REMOTE_TUNNEL}:${destination_port}" \
            -m comment \
            --comment "PICASO PF ${id}" \
            2>/dev/null || {

            iptables -t nat -A PREROUTING \
                -i "$wan" \
                -p "$proto" \
                -d "$LOCAL_PUBLIC" \
                --dport "$public_port" \
                -j DNAT \
                --to-destination "${REMOTE_TUNNEL}:${destination_port}" \
                -m comment \
                --comment "PICASO PF ${id}"
        }

        # ----------------------------------------------------
        # CLIENT -> FOREIGN
        # ----------------------------------------------------

        iptables -C FORWARD \
            -i "$wan" \
            -o "$INTERFACE" \
            -p "$proto" \
            -d "$REMOTE_TUNNEL" \
            --dport "$destination_port" \
            -m conntrack \
            --ctstate NEW,ESTABLISHED,RELATED \
            -j ACCEPT \
            -m comment \
            --comment "PICASO PF ${id}" \
            2>/dev/null || {

            iptables -A FORWARD \
                -i "$wan" \
                -o "$INTERFACE" \
                -p "$proto" \
                -d "$REMOTE_TUNNEL" \
                --dport "$destination_port" \
                -m conntrack \
                --ctstate NEW,ESTABLISHED,RELATED \
                -j ACCEPT \
                -m comment \
                --comment "PICASO PF ${id}"
        }

        # ----------------------------------------------------
        # FOREIGN -> IRAN -> CLIENT
        # ----------------------------------------------------

        iptables -C FORWARD \
            -i "$INTERFACE" \
            -o "$wan" \
            -p "$proto" \
            -s "$REMOTE_TUNNEL" \
            --sport "$destination_port" \
            -m conntrack \
            --ctstate ESTABLISHED,RELATED \
            -j ACCEPT \
            -m comment \
            --comment "PICASO PF ${id}" \
            2>/dev/null || {

            iptables -A FORWARD \
                -i "$INTERFACE" \
                -o "$wan" \
                -p "$proto" \
                -s "$REMOTE_TUNNEL" \
                --sport "$destination_port" \
                -m conntrack \
                --ctstate ESTABLISHED,RELATED \
                -j ACCEPT \
                -m comment \
                --comment "PICASO PF ${id}"
        }

        # ----------------------------------------------------
        # IMPORTANT:
        #
        # Foreign Xray must see the connection as coming from
        # the Iran GRE endpoint (132.168.x.x).
        #
        # This guarantees that the Foreign server sends the
        # response back through GRE.
        # ----------------------------------------------------

        iptables -t nat -C POSTROUTING \
            -o "$INTERFACE" \
            -p "$proto" \
            -d "$REMOTE_TUNNEL" \
            --dport "$destination_port" \
            -j MASQUERADE \
            -m comment \
            --comment "PICASO PF ${id}" \
            2>/dev/null || {

            iptables -t nat -A POSTROUTING \
                -o "$INTERFACE" \
                -p "$proto" \
                -d "$REMOTE_TUNNEL" \
                --dport "$destination_port" \
                -j MASQUERADE \
                -m comment \
                --comment "PICASO PF ${id}"
        }

        log "Port forwarding ${id}: ${proto} ${public_port} -> ${REMOTE_TUNNEL}:${destination_port}"

    done < "$file"

    ok "Port forwarding rules applied for tunnel ${id}."
}

# ============================================================
# DELETE ALL PICASO FIREWALL RULES FOR TUNNEL
# ============================================================

remove_tunnel_firewall() {

    local id="$1"

    load_tunnel "$id" || return 0

    local file="${PORT_DIR}/${id}.rules"

    if [[ -f "$file" ]]; then

        while IFS='|' read -r proto public_port destination_port; do

            [[ -z "$proto" ]] && continue
            [[ "$proto" =~ ^# ]] && continue

            local wan
            wan=$(ip route show default | awk 'NR==1{print $5}')

            # DNAT
            while iptables -t nat -C PREROUTING \
                -i "$wan" \
                -p "$proto" \
                -d "$LOCAL_PUBLIC" \
                --dport "$public_port" \
                -j DNAT \
                --to-destination "${REMOTE_TUNNEL}:${destination_port}" \
                -m comment \
                --comment "PICASO PF ${id}" \
                2>/dev/null; do

                iptables -t nat -D PREROUTING \
                    -i "$wan" \
                    -p "$proto" \
                    -d "$LOCAL_PUBLIC" \
                    --dport "$public_port" \
                    -j DNAT \
                    --to-destination "${REMOTE_TUNNEL}:${destination_port}" \
                    -m comment \
                    --comment "PICASO PF ${id}" || true
            done

            # FORWARD
            while iptables -C FORWARD \
                -i "$wan" \
                -o "$INTERFACE" \
                -p "$proto" \
                -d "$REMOTE_TUNNEL" \
                --dport "$destination_port" \
                -m conntrack \
                --ctstate NEW,ESTABLISHED,RELATED \
                -j ACCEPT \
                -m comment \
                --comment "PICASO PF ${id}" \
                2>/dev/null; do

                iptables -D FORWARD \
                    -i "$wan" \
                    -o "$INTERFACE" \
                    -p "$proto" \
                    -d "$REMOTE_TUNNEL" \
                    --dport "$destination_port" \
                    -m conntrack \
                    --ctstate NEW,ESTABLISHED,RELATED \
                    -j ACCEPT \
                    -m comment \
                    --comment "PICASO PF ${id}" || true
            done

            # RETURN FORWARD
            while iptables -C FORWARD \
                -i "$INTERFACE" \
                -o "$wan" \
                -p "$proto" \
                -s "$REMOTE_TUNNEL" \
                --sport "$destination_port" \
                -m conntrack \
                --ctstate ESTABLISHED,RELATED \
                -j ACCEPT \
                -m comment \
                --comment "PICASO PF ${id}" \
                2>/dev/null; do

                iptables -D FORWARD \
                    -i "$INTERFACE" \
                    -o "$wan" \
                    -p "$proto" \
                    -s "$REMOTE_TUNNEL" \
                    --sport "$destination_port" \
                    -m conntrack \
                    --ctstate ESTABLISHED,RELATED \
                    -j ACCEPT \
                    -m comment \
                    --comment "PICASO PF ${id}" || true
            done

            # MASQUERADE
            while iptables -t nat -C POSTROUTING \
                -o "$INTERFACE" \
                -p "$proto" \
                -d "$REMOTE_TUNNEL" \
                --dport "$destination_port" \
                -j MASQUERADE \
                -m comment \
                --comment "PICASO PF ${id}" \
                2>/dev/null; do

                iptables -t nat -D POSTROUTING \
                    -o "$INTERFACE" \
                    -p "$proto" \
                    -d "$REMOTE_TUNNEL" \
                    --dport "$destination_port" \
                    -j MASQUERADE \
                    -m comment \
                    --comment "PICASO PF ${id}" || true
            done

        done < "$file"
    fi

    remove_gre_firewall "$REMOTE_PUBLIC" "$INTERFACE"
}

# ============================================================
# START / STOP
# ============================================================

start_tunnel() {

    local id="$1"

    load_tunnel "$id" || die "Tunnel $id does not exist."

    if [[ "$ROLE" != "IRAN" && "$ROLE" != "FOREIGN" ]]; then
        die "Invalid tunnel role."
    fi

    sed -i 's/^ENABLED=.*/ENABLED=1/' "${TUNNEL_DIR}/${id}.conf"

    create_gre "$id"

    if [[ "$ROLE" == "IRAN" ]]; then
        apply_port_rules "$id"
    fi

    ok "Tunnel $id started."
    log "Tunnel $id started."
}

stop_tunnel() {

    local id="$1"

    load_tunnel "$id" || die "Tunnel $id does not exist."

    sed -i 's/^ENABLED=.*/ENABLED=0/' "${TUNNEL_DIR}/${id}.conf"

    remove_tunnel_firewall "$id"

    delete_interface "$INTERFACE"

    ok "Tunnel $id stopped."
    log "Tunnel $id stopped."
}

restart_tunnel() {

    local id="$1"

    stop_tunnel "$id"
    sleep 1
    start_tunnel "$id"
}

delete_tunnel() {

    local id="$1"

    load_tunnel "$id" || die "Tunnel $id does not exist."

    echo
    warn "This will permanently delete tunnel ${id}."
    read -r -p "Type DELETE to continue: " confirm

    [[ "$confirm" == "DELETE" ]] || {
        warn "Cancelled."
        return
    }

    remove_tunnel_firewall "$id"
    delete_interface "$INTERFACE"

    rm -f "${TUNNEL_DIR}/${id}.conf"
    rm -f "${PORT_DIR}/${id}.rules"

    ok "Tunnel $id deleted."
    log "Tunnel $id deleted."
}

# ============================================================
# TEST
# ============================================================

test_tunnel() {

    local id="$1"

    load_tunnel "$id" || die "Tunnel $id does not exist."

    echo
    echo "========================================"
    echo " PICASO Tunnel Test - ${id}"
    echo "========================================"
    echo

    echo "Interface:"
    ip -d link show "$INTERFACE" 2>/dev/null || {
        error "Interface does not exist."
        return
    }

    echo
    echo "Addresses:"
    ip addr show "$INTERFACE"

    echo
    echo "Route:"
    ip route get "$REMOTE_TUNNEL" 2>/dev/null || true

    echo
    echo "Ping remote tunnel:"
    if ping -I "$INTERFACE" -c 3 -W 2 "$REMOTE_TUNNEL"; then
        ok "GRE tunnel is reachable."
    else
        error "Remote tunnel IP is not reachable."
    fi

    echo
    echo "Traffic:"
    ip -s link show "$INTERFACE"

    echo
    echo "GRE packets:"
    echo "Use:"
    echo "  tcpdump -ni any 'ip proto 47'"
}

# ============================================================
# DETAILS
# ============================================================

show_details() {

    local id="$1"

    load_tunnel "$id" || die "Tunnel $id does not exist."

    echo
    echo "========================================"
    echo " Tunnel ${id}"
    echo "========================================"
    echo
    echo "Role           : $ROLE"
    echo "Interface      : $INTERFACE"
    echo "Local public   : $LOCAL_PUBLIC"
    echo "Remote public  : $REMOTE_PUBLIC"
    echo "Local tunnel   : $LOCAL_TUNNEL"
    echo "Remote tunnel  : $REMOTE_TUNNEL"
    echo "Subnet         : $SUBNET"
    echo "MTU            : $MTU"
    echo "Enabled        : $ENABLED"

    echo
    echo "Port forwarding:"

    if [[ -f "${PORT_DIR}/${id}.rules" ]] &&
       [[ -s "${PORT_DIR}/${id}.rules" ]]; then

        while IFS='|' read -r proto public destination; do
            echo "  ${proto}: ${public} -> ${REMOTE_TUNNEL}:${destination}"
        done < "${PORT_DIR}/${id}.rules"

    else
        echo "  None"
    fi
}

# ============================================================
# TRAFFIC
# ============================================================

show_traffic() {

    local id="$1"

    load_tunnel "$id" || die "Tunnel $id does not exist."

    echo
    ip -s link show "$INTERFACE"
}

# ============================================================
# PORT FORWARD MENU
# ============================================================

port_forward_menu() {

    local id="$1"

    load_tunnel "$id" || die "Tunnel $id does not exist."

    [[ "$ROLE" == "IRAN" ]] || {
        warn "Port forwarding is configured on the IRAN side."
        pause
        return
    }

    while true; do

        clear

        echo "========================================"
        echo " PICASO - Port Forwarding"
        echo " Tunnel: $id"
        echo "========================================"
        echo
        echo "Foreign tunnel IP: $REMOTE_TUNNEL"
        echo
        echo "1) Add forwarding"
        echo "2) Remove forwarding"
        echo "3) List forwarding"
        echo "4) Re-apply rules"
        echo "0) Back"
        echo

        read -r -p "Select: " choice

        case "$choice" in

            1)
                echo
                read -r -p "Protocol (tcp/udp): " proto
                read -r -p "Public Iran port: " public_port
                read -r -p "Foreign destination port: " destination_port

                add_port_rule \
                    "$id" \
                    "$proto" \
                    "$public_port" \
                    "$destination_port"

                pause
                ;;

            2)
                echo
                read -r -p "Protocol (tcp/udp): " proto
                read -r -p "Public Iran port: " public_port
                read -r -p "Foreign destination port: " destination_port

                remove_port_rule \
                    "$id" \
                    "$proto" \
                    "$public_port" \
                    "$destination_port"

                pause
                ;;

            3)
                echo
                if [[ -f "${PORT_DIR}/${id}.rules" ]]; then
                    cat "${PORT_DIR}/${id}.rules"
                else
                    echo "No rules."
                fi
                pause
                ;;

            4)
                clear_port_rules "$id"
                apply_port_rules "$id"
                pause
                ;;

            0)
                return
                ;;

            *)
                warn "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# MANAGE TUNNEL
# ============================================================

manage_tunnel() {

    local id="$1"

    while true; do

        clear

        echo "========================================"
        echo " PICASO - Manage Tunnel ${id}"
        echo "========================================"

        show_details "$id"

        echo
        echo "----------------------------------------"
        echo "1) Start"
        echo "2) Stop"
        echo "3) Restart"
        echo "4) Test"
        echo "5) Details"
        echo "6) Traffic"
        echo "7) Port Forwarding"
        echo "8) Delete"
        echo "0) Back"
        echo "----------------------------------------"

        read -r -p "Select: " choice

        case "$choice" in

            1)
                start_tunnel "$id"
                pause
                ;;

            2)
                stop_tunnel "$id"
                pause
                ;;

            3)
                restart_tunnel "$id"
                pause
                ;;

            4)
                test_tunnel "$id"
                pause
                ;;

            5)
                show_details "$id"
                pause
                ;;

            6)
                show_traffic "$id"
                pause
                ;;

            7)
                port_forward_menu "$id"
                ;;

            8)
                delete_tunnel "$id"
                pause
                return
                ;;

            0)
                return
                ;;

            *)
                warn "Invalid option."
                ;;
        esac
    done
}

# ============================================================
# LIST TUNNELS
# ============================================================

list_tunnels() {

    echo
    echo "========================================"
    echo " PICASO Connections"
    echo "========================================"
    echo

    local found=0

    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -e "$file" ]] || continue

        found=1

        # shellcheck disable=SC1090
        source "$file"

        local status="DOWN"

        if interface_exists "$INTERFACE"; then

            if ping -I "$INTERFACE" \
                -c 1 \
                -W 1 \
                "$REMOTE_TUNNEL" >/dev/null 2>&1; then

                status="UP"

            else
                status="DEGRADED"
            fi

        else

            if [[ "${ENABLED:-0}" == "1" ]]; then
                status="MISSING"
            else
                status="STOPPED"
            fi
        fi

        printf "ID %-4s | %-8s | %-14s | %-15s | %-15s | %s\n" \
            "$ID" \
            "$status" \
            "$ROLE" \
            "$LOCAL_PUBLIC" \
            "$REMOTE_PUBLIC" \
            "$INTERFACE"
    done

    [[ "$found" -eq 1 ]] || echo "No tunnels configured."

    echo
}

# ============================================================
# CHECK ALL
# ============================================================

check_all() {

    clear

    list_tunnels

    echo "Detailed checks:"
    echo

    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -e "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"

        printf "%-4s %-15s -> %-15s : " \
            "$ID" \
            "$LOCAL_TUNNEL" \
            "$REMOTE_TUNNEL"

        if interface_exists "$INTERFACE" &&
           ping -I "$INTERFACE" \
                -c 1 \
                -W 1 \
                "$REMOTE_TUNNEL" >/dev/null 2>&1; then

            echo -e "${GREEN}OK${RESET}"

        else
            echo -e "${RED}FAILED${RESET}"
        fi
    done

    pause
}

# ============================================================
# REPAIR / SYNCHRONIZE
# ============================================================

repair_all() {

    clear

    echo "========================================"
    echo " PICASO Repair / Synchronize"
    echo "========================================"
    echo

    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -e "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"

        if [[ "${ENABLED:-0}" == "1" ]]; then

            info "Repairing tunnel ${ID}..."

            create_gre "$ID"

            if [[ "$ROLE" == "IRAN" ]]; then
                apply_port_rules "$ID"
            fi

        fi
    done

    ok "Repair completed."
    log "Repair completed."

    pause
}

# ============================================================
# ADD TUNNEL
# ============================================================

add_tunnel() {

    clear

    echo "========================================"
    echo " PICASO - Add New Connection"
    echo "========================================"
    echo

    echo "1) IRAN"
    echo "2) FOREIGN"
    echo

    read -r -p "Server role: " role_choice

    case "$role_choice" in
        1) role="IRAN" ;;
        2) role="FOREIGN" ;;
        *)
            error "Invalid role."
            pause
            return
            ;;
    esac

    echo

    local detected
    detected=$(detect_public_ip || true)

    if [[ -n "$detected" ]]; then
        echo "Detected public IP: $detected"
    fi

    read -r -p "This server public IP [${detected}]: " local_public

    [[ -n "$local_public" ]] || local_public="$detected"

    valid_ipv4 "$local_public" ||
        die "Invalid local public IPv4."

    read -r -p "Remote server public IP: " remote_public

    valid_ipv4 "$remote_public" ||
        die "Invalid remote public IPv4."

    [[ "$local_public" != "$remote_public" ]] ||
        die "Local and remote public IP cannot be identical."

    # Check duplicate remote/public pair
    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -e "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"

        if [[ "$LOCAL_PUBLIC" == "$local_public" &&
              "$REMOTE_PUBLIC" == "$remote_public" ]]; then

            die "This exact tunnel already exists."
        fi
    done

    local id
    id=$(get_next_id)

    local iface="picaso-gre${id}"

    local subnet
    subnet=$(get_subnet_for_id "$id")

    local local_tun
    local remote_tun

    if [[ "$role" == "IRAN" ]]; then

        local_tun=$(subnet_local_ip "$subnet")
        remote_tun=$(subnet_remote_ip "$subnet")

    else

        local_tun=$(subnet_remote_ip "$subnet")
        remote_tun=$(subnet_local_ip "$subnet")

    fi

    local mtu=1476

    echo
    echo "----------------------------------------"
    echo "Tunnel ID       : $id"
    echo "Role            : $role"
    echo "Interface       : $iface"
    echo "Local public    : $local_public"
    echo "Remote public   : $remote_public"
    echo "Subnet          : $subnet"
    echo "Local tunnel IP : $local_tun"
    echo "Remote tunnel IP: $remote_tun"
    echo "MTU             : $mtu"
    echo "----------------------------------------"
    echo

    read -r -p "Create this tunnel? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || {
        warn "Cancelled."
        pause
        return
    }

    save_tunnel \
        "$id" \
        "$role" \
        "$local_public" \
        "$remote_public" \
        "$iface" \
        "$local_tun" \
        "$remote_tun" \
        "$subnet" \
        "$mtu"

    touch "${PORT_DIR}/${id}.rules"

    create_gre "$id"

    if [[ "$role" == "IRAN" ]]; then
        enable_forwarding
    fi

    ok "Tunnel ${id} created successfully."

    echo
    echo "IMPORTANT:"
    echo
    echo "On the IRAN server:"
    echo "  Add Port Forwarding rules."
    echo
    echo "Example:"
    echo "  TCP 443 -> 443"
    echo
    echo "Then the client uses:"
    echo "  ${local_public}:443"
    echo
    echo "Traffic will be:"
    echo "  Client"
    echo "    -> ${local_public}:443"
    echo "    -> ${remote_tun}:443"
    echo "    -> Foreign Xray"
    echo

    pause
}

# ============================================================
# BBR
# ============================================================

install_bbr() {

    echo
    echo "Current congestion control:"
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true

    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then

        if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
            warn "BBR is not available in the current kernel."
            return
        fi
    fi

    cat > /etc/sysctl.d/99-picaso-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || true

    ok "BBR configuration applied."
}

# ============================================================
# NETWORK OPTIMIZATION
# ============================================================

optimize_network() {

    cat > /etc/sysctl.d/99-picaso-network.conf <<EOF
net.ipv4.ip_forward=1

net.ipv4.tcp_syncookies=1

net.ipv4.tcp_fin_timeout=15

net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5

net.ipv4.tcp_mtu_probing=1

net.core.somaxconn=4096
net.core.netdev_max_backlog=16384

net.ipv4.tcp_max_syn_backlog=8192

net.ipv4.ip_local_port_range=1024 65535
EOF

    sysctl --system >/dev/null 2>&1 || true

    ok "Network optimization applied."
}

# ============================================================
# OPTIMIZATION MENU
# ============================================================

optimization_menu() {

    while true; do

        clear

        echo "========================================"
        echo " PICASO - Server Optimization"
        echo "========================================"
        echo
        echo "1) Install / Enable BBR"
        echo "2) Optimize TCP / Network"
        echo "3) Enable IPv4 Forwarding"
        echo "4) Apply All Recommended"
        echo "5) Show Current Settings"
        echo "0) Back"
        echo

        read -r -p "Select: " choice

        case "$choice" in

            1)
                install_bbr
                pause
                ;;

            2)
                optimize_network
                pause
                ;;

            3)
                enable_forwarding
                ok "IPv4 forwarding enabled."
                pause
                ;;

            4)
                install_bbr
                optimize_network
                enable_forwarding
                ok "All recommended optimizations applied."
                pause
                ;;

            5)
                echo
                sysctl net.ipv4.ip_forward
                sysctl net.ipv4.tcp_congestion_control
                sysctl net.core.default_qdisc
                echo
                cat /proc/sys/net/ipv4/tcp_available_congestion_control
                pause
                ;;

            0)
                return
                ;;

            *)
                warn "Invalid option."
                ;;
        esac
    done
}

# ============================================================
# RESTORE SCRIPT
# ============================================================

install_restore_script() {

    cat > "$RESTORE" <<'EOF'
#!/usr/bin/env bash

set -u

BASE_DIR="/etc/picaso"
TUNNEL_DIR="${BASE_DIR}/tunnels"
BIN="/usr/local/bin/picaso"

sleep 3

if [[ -x "$BIN" ]]; then
    "$BIN" --restore
fi
EOF

    chmod +x "$RESTORE"
}

# ============================================================
# MONITOR SCRIPT
# ============================================================

install_monitor_script() {

    cat > "$MONITOR" <<'EOF'
#!/usr/bin/env bash

set -u

BASE_DIR="/etc/picaso"
TUNNEL_DIR="${BASE_DIR}/tunnels"
LOG_FILE="/var/log/picaso.log"

mkdir -p "$(dirname "$LOG_FILE")"

declare -A LAST_STATE

log_state() {
    echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

while true; do

    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -e "$file" ]] || continue

        unset ID ROLE INTERFACE LOCAL_PUBLIC REMOTE_PUBLIC
        unset LOCAL_TUNNEL REMOTE_TUNNEL SUBNET MTU ENABLED

        # shellcheck disable=SC1090
        source "$file"

        [[ "${ENABLED:-0}" == "1" ]] || continue

        state="MISSING"

        if ip link show "$INTERFACE" >/dev/null 2>&1; then

            if ping -I "$INTERFACE" \
                -c 1 \
                -W 1 \
                "$REMOTE_TUNNEL" >/dev/null 2>&1; then

                state="UP"
            else
                state="DEGRADED"
            fi
        fi

        previous="${LAST_STATE[$ID]:-UNKNOWN}"

        if [[ "$state" != "$previous" ]]; then
            log_state "Tunnel ${ID} state changed: ${previous} -> ${state}"
            LAST_STATE[$ID]="$state"
        fi

    done

    sleep 30
done
EOF

    chmod +x "$MONITOR"
}

# ============================================================
# SYSTEMD
# ============================================================

install_systemd() {

    install_restore_script
    install_monitor_script

    cat > "/etc/systemd/system/${RESTORE_SERVICE}" <<EOF
[Unit]
Description=PICASO GRE Tunnel Restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RESTORE}

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/${MONITOR_SERVICE}" <<EOF
[Unit]
Description=PICASO GRE Tunnel Monitor
After=network-online.target ${RESTORE_SERVICE}
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MONITOR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable "$RESTORE_SERVICE" >/dev/null 2>&1 || true
    systemctl enable "$MONITOR_SERVICE" >/dev/null 2>&1 || true

    systemctl restart "$MONITOR_SERVICE" >/dev/null 2>&1 || true
}

# ============================================================
# RESTORE MODE
# ============================================================

restore_all() {

    init_dirs

    enable_forwarding

    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -e "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"

        [[ "${ENABLED:-0}" == "1" ]] || continue

        # Re-create tunnel directly here to avoid recursion
        if ! interface_exists "$INTERFACE"; then

            ip tunnel add "$INTERFACE" \
                mode gre \
                local "$LOCAL_PUBLIC" \
                remote "$REMOTE_PUBLIC" \
                ttl 255 2>/dev/null || true
        fi

        ip link set "$INTERFACE" mtu "$MTU" 2>/dev/null || true
        ip link set "$INTERFACE" up 2>/dev/null || true

        if ! ip addr show dev "$INTERFACE" |
            grep -q "inet ${LOCAL_TUNNEL}/"; then

            ip addr add "${LOCAL_TUNNEL}/30" dev "$INTERFACE" \
                2>/dev/null || true
        fi

        add_gre_firewall "$REMOTE_PUBLIC" "$INTERFACE" 2>/dev/null || true

        if [[ "$ROLE" == "IRAN" ]]; then
            apply_port_rules "$ID" 2>/dev/null || true
        fi
    done

    log "PICASO restore completed."
}

# ============================================================
# LOGS
# ============================================================

show_logs() {

    echo
    echo "========================================"
    echo " PICASO Logs"
    echo "========================================"
    echo

    if [[ -f "$LOG_FILE" ]]; then
        tail -n 100 "$LOG_FILE"
    else
        echo "No logs."
    fi

    pause
}

# ============================================================
# UNINSTALL
# ============================================================

uninstall_picaso() {

    clear

    echo "========================================"
    echo " PICASO COMPLETE UNINSTALL"
    echo "========================================"
    echo
    echo "This will remove:"
    echo
    echo " - All PICASO GRE interfaces"
    echo " - All PICASO port-forward rules"
    echo " - PICASO GRE firewall rules"
    echo " - PICASO systemd services"
    echo " - PICASO configuration"
    echo " - PICASO logs"
    echo " - picaso command"
    echo
    echo "It will NOT:"
    echo
    echo " - Flush all iptables"
    echo " - Delete gre0"
    echo " - Delete unrelated firewall rules"
    echo

    read -r -p "Type DELETE to continue: " confirm

    [[ "$confirm" == "DELETE" ]] || {
        warn "Cancelled."
        pause
        return
    }

    # Stop services
    systemctl disable --now "$MONITOR_SERVICE" \
        >/dev/null 2>&1 || true

    systemctl disable "$RESTORE_SERVICE" \
        >/dev/null 2>&1 || true

    # Remove every tunnel
    for file in "$TUNNEL_DIR"/*.conf; do

        [[ -e "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"

        remove_tunnel_firewall "$ID" || true
        delete_interface "$INTERFACE" || true
    done

    # Remove systemd files
    rm -f "/etc/systemd/system/${RESTORE_SERVICE}"
    rm -f "/etc/systemd/system/${MONITOR_SERVICE}"

    systemctl daemon-reload

    # Remove sysctl files
    rm -f /etc/sysctl.d/99-picaso-forwarding.conf
    rm -f /etc/sysctl.d/99-picaso-bbr.conf
    rm -f /etc/sysctl.d/99-picaso-network.conf

    # Remove configuration
    rm -rf "$BASE_DIR"

    # Remove scripts
    rm -f "$BIN"
    rm -f "$RESTORE"
    rm -f "$MONITOR"

    # Remove log
    rm -f "$LOG_FILE"

    ok "PICASO completely removed."
    echo
    echo "gre0 and unrelated iptables rules were left untouched."

    exit 0
}

# ============================================================
# INSTALL MANAGER
# ============================================================

install_manager() {

    if [[ "$0" != "$BIN" ]]; then

        cp "$0" "$BIN"
        chmod +x "$BIN"

    fi
}

# ============================================================
# MAIN MENU
# ============================================================

main_menu() {

    while true; do

        clear

        echo -e "${CYAN}"
        echo "=============================================="
        echo "                 PICASO"
        echo "          Multi GRE Tunnel Manager"
        echo "                 v${VERSION}"
        echo "=============================================="
        echo -e "${RESET}"

        list_tunnels

        echo "----------------------------------------------"
        echo "1) Add New Connection"
        echo "2) Manage A Connection"
        echo "3) Check All Connections"
        echo "4) Repair / Synchronize"
        echo "5) Server Optimization"
        echo "6) Logs"
        echo "7) Complete Uninstall"
        echo "0) Exit"
        echo "----------------------------------------------"
        echo

        read -r -p "Select: " choice

        case "$choice" in

            1)
                add_tunnel
                ;;

            2)
                echo
                read -r -p "Tunnel ID: " id

                if tunnel_exists "$id"; then
                    manage_tunnel "$id"
                else
                    error "Tunnel $id not found."
                    pause
                fi
                ;;

            3)
                check_all
                ;;

            4)
                repair_all
                ;;

            5)
                optimization_menu
                ;;

            6)
                show_logs
                ;;

            7)
                uninstall_picaso
                ;;

            0)
                clear
                echo "PICASO exited."
                exit 0
                ;;

            *)
                warn "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# INTERNAL RESTORE MODE
# ============================================================

if [[ "${1:-}" == "--restore" ]]; then

    require_root
    require_commands
    init_dirs

    # Functions needed by restore
    restore_all

    exit 0
fi

# ============================================================
# INSTALL / START
# ============================================================

require_root
require_commands
init_dirs

# Copy manager
if [[ "$0" != "$BIN" ]]; then
    install_manager
fi

install_systemd

main_menu
