#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="3.1.0"

BASE="/etc/picaso"
TUNNELS="$BASE/tunnels"
PORTS="$BASE/ports"
STATE="$BASE/next_id"

LOG="/var/log/picaso.log"

BIN="/usr/local/bin/picaso"
RESTORE="/usr/local/sbin/picaso-restore"
MONITOR="/usr/local/sbin/picaso-monitor"

RESTORE_UNIT="picaso-restore.service"
MONITOR_UNIT="picaso-monitor.service"

SYSCTL_FORWARD="/etc/sysctl.d/99-picaso-forwarding.conf"
SYSCTL_BBR="/etc/sysctl.d/99-picaso-bbr.conf"
SYSCTL_NET="/etc/sysctl.d/99-picaso-network.conf"

C='\033[0;36m'
G='\033[0;32m'
Y='\033[1;33m'
R='\033[0;31m'
X='\033[0m'


# ============================================================
# BASIC
# ============================================================

log() {
    mkdir -p "$(dirname "$LOG")"
    printf '[%s] %s\n' \
        "$(date '+%F %T')" \
        "$*" >> "$LOG"
}

info() {
    printf '%b[INFO]%b %s\n' "$C" "$X" "$*"
}

ok() {
    printf '%b[ OK ]%b %s\n' "$G" "$X" "$*"
}

warn() {
    printf '%b[WARN]%b %s\n' "$Y" "$X" "$*" >&2
}

err() {
    printf '%b[ERROR]%b %s\n' "$R" "$X" "$*" >&2
}

die() {
    err "$*"
    exit 1
}

pause() {
    read -r -p "Press Enter to continue..." _ || true
}

clear_screen() {
    command -v clear >/dev/null 2>&1 && clear || true
}


trap 'rc=$?; err "Failed at line $LINENO: $BASH_COMMAND (exit $rc)"; exit $rc' ERR


# ============================================================
# ROOT / DEPENDENCIES
# ============================================================

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Run this script as root."
}


install_missing() {

    local -a missing=()

    for cmd in ip iptables systemctl awk sed grep ping sysctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    command -v apt-get >/dev/null 2>&1 || {
        die "Missing commands: ${missing[*]}. Install iproute2 iptables iputils-ping procps."
    }

    info "Required packages are missing."
    info "Installing: iproute2 iptables iputils-ping procps"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y \
        iproute2 \
        iptables \
        iputils-ping \
        procps
}


require_commands() {

    local cmd

    for cmd in \
        ip \
        iptables \
        systemctl \
        awk \
        sed \
        grep \
        ping \
        sysctl
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command not found: $cmd"
    done
}


# ============================================================
# INITIALIZATION
# ============================================================

init() {

    mkdir -p "$BASE"
    mkdir -p "$TUNNELS"
    mkdir -p "$PORTS"

    touch "$LOG"

    chmod 700 "$BASE" "$TUNNELS" "$PORTS" 2>/dev/null || true

    if [[ ! -f "$STATE" ]]; then
        echo "1" > "$STATE"
    fi
}


# ============================================================
# VALIDATION
# ============================================================

valid_ipv4() {

    local ip="$1"
    local IFS=.
    local a b c d

    read -r a b c d <<< "$ip" || return 1

    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    [[ "$b" =~ ^[0-9]+$ ]] || return 1
    [[ "$c" =~ ^[0-9]+$ ]] || return 1
    [[ "$d" =~ ^[0-9]+$ ]] || return 1

    ((a <= 255))
    ((b <= 255))
    ((c <= 255))
    ((d <= 255))
}

valid_port() {

    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    ((port >= 1 && port <= 65535))
}

valid_proto() {

    case "$1" in
        tcp|udp)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

valid_id() {

    [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1

    (( "$1" <= 100000 ))
}


# ============================================================
# NETWORK INFORMATION
# ============================================================

wan_iface() {

    ip route show default 2>/dev/null |
        awk 'NR==1 {print $5}'
}


detect_public_ip() {

    local ip=""
    local wan=""

    wan="$(wan_iface || true)"

    if [[ -n "$wan" ]]; then

        ip="$(
            ip -4 addr show dev "$wan" scope global 2>/dev/null |
            awk '/inet / {
                sub("/.*","",$2)
                print $2
                exit
            }' || true
        )"

        if valid_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    fi

    ip="$(
        ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{
            for (i=1;i<=NF;i++) {
                if ($i=="src") {
                    print $(i+1)
                    exit
                }
            }
        }' || true
    )"

    if valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    return 1
}


local_ipv4_exists() {

    local ip="$1"

    ip -4 addr show |
        awk '{print $2}' |
        grep -Eq "^${ip}/[0-9]+$"
}


# ============================================================
# ID MANAGEMENT
# ============================================================

next_id() {

    local id

    id="$(cat "$STATE" 2>/dev/null || echo 1)"

    [[ "$id" =~ ^[0-9]+$ ]] || id=1

    while [[ -e "$TUNNELS/${id}.conf" ]]; do
        ((id++))
    done

    echo $((id + 1)) > "$STATE"

    echo "$id"
}


reserve_manual_id() {

    local id="$1"
    local next

    valid_id "$id" ||
        die "Invalid tunnel ID."

    [[ ! -e "$TUNNELS/${id}.conf" ]] ||
        die "Tunnel ID $id already exists."

    next="$(cat "$STATE" 2>/dev/null || echo 1)"

    [[ "$next" =~ ^[0-9]+$ ]] || next=1

    if ((id >= next)); then
        echo $((id + 1)) > "$STATE"
    fi
}


# ============================================================
# SUBNET ALLOCATION
# ============================================================

subnet_for_id() {

    local id="$1"
    local index=$((id - 1))
    local second=$((index / 64))
    local block=$((index % 64))

    ((second <= 255)) ||
        die "Tunnel ID is too large."

    echo "10.250.${second}.$((block * 4))/30"
}


ip_plus() {

    local subnet="$1"
    local offset="$2"

    awk -F'[./]' -v o="$offset" '
    {
        print $1 "." $2 "." $3 "." ($4 + o)
    }' <<< "$subnet"
}


# ============================================================
# CONFIG
# ============================================================

save_cfg() {

    local id="$1"
    local role="$2"
    local local_public="$3"
    local remote_public="$4"
    local iface="$5"
    local local_tun="$6"
    local remote_tun="$7"
    local subnet="$8"
    local mtu="$9"

    cat > "$TUNNELS/${id}.conf" <<EOF
ID=$id
ROLE=$role
LOCAL_PUBLIC=$local_public
REMOTE_PUBLIC=$remote_public
INTERFACE=$iface
LOCAL_TUNNEL=$local_tun
REMOTE_TUNNEL=$remote_tun
SUBNET=$subnet
MTU=$mtu
ENABLED=1
EOF
}


load_cfg() {

    local id="$1"
    local file="$TUNNELS/${id}.conf"

    [[ -f "$file" ]] || return 1

    unset \
        ID \
        ROLE \
        LOCAL_PUBLIC \
        REMOTE_PUBLIC \
        INTERFACE \
        LOCAL_TUNNEL \
        REMOTE_TUNNEL \
        SUBNET \
        MTU \
        ENABLED

    # shellcheck disable=SC1090
    source "$file"
}


iface_exists() {

    ip link show "$1" >/dev/null 2>&1
}


# ============================================================
# GRE FIREWALL
# ============================================================

gre_fw_add() {

    local remote_public="$1"
    local iface="$2"

    if ! iptables -C INPUT \
        -p 47 \
        -s "$remote_public" \
        -m comment \
        --comment "PICASO GRE $iface" \
        -j ACCEPT 2>/dev/null
    then

        iptables -I INPUT 1 \
            -p 47 \
            -s "$remote_public" \
            -m comment \
            --comment "PICASO GRE $iface" \
            -j ACCEPT
    fi


    if ! iptables -C INPUT \
        -i "$iface" \
        -m comment \
        --comment "PICASO TUNNEL $iface" \
        -j ACCEPT 2>/dev/null
    then

        iptables -I INPUT 1 \
            -i "$iface" \
            -m comment \
            --comment "PICASO TUNNEL $iface" \
            -j ACCEPT
    fi
}


delete_rule() {

    while iptables "$@" 2>/dev/null; do
        :
    done
}


gre_fw_del() {

    local remote_public="$1"
    local iface="$2"

    delete_rule \
        -D INPUT \
        -p 47 \
        -s "$remote_public" \
        -m comment \
        --comment "PICASO GRE $iface" \
        -j ACCEPT

    delete_rule \
        -D INPUT \
        -i "$iface" \
        -m comment \
        --comment "PICASO TUNNEL $iface" \
        -j ACCEPT
}


# ============================================================
# GRE CREATION
# ============================================================

create_gre() {

    local id="$1"

    load_cfg "$id" ||
        die "Tunnel $id not found."

    info "Configuring ${INTERFACE}..."


    if iface_exists "$INTERFACE"; then

        local details

        details="$(
            ip -d link show "$INTERFACE" 2>/dev/null || true
        )

        if ! grep -q "remote ${REMOTE_PUBLIC}" <<< "$details" ||
           ! grep -q "local ${LOCAL_PUBLIC}" <<< "$details"
        then

            warn "${INTERFACE} exists with different endpoints."
            warn "Recreating ${INTERFACE}."

            ip tunnel del "$INTERFACE" 2>/dev/null || true
        fi
    fi


    if ! iface_exists "$INTERFACE"; then

        ip tunnel add "$INTERFACE" \
            mode gre \
            local "$LOCAL_PUBLIC" \
            remote "$REMOTE_PUBLIC" \
            ttl 255
    fi


    ip link set "$INTERFACE" mtu "$MTU"
    ip link set "$INTERFACE" up


    if ! ip addr show dev "$INTERFACE" |
        grep -q "inet ${LOCAL_TUNNEL}/"
    then

        ip addr add \
            "${LOCAL_TUNNEL}/30" \
            dev "$INTERFACE"
    fi


    gre_fw_add \
        "$REMOTE_PUBLIC" \
        "$INTERFACE"


    ok "Tunnel $id: ${INTERFACE} configured."

    log "Tunnel $id GRE configured: ${LOCAL_PUBLIC} -> ${REMOTE_PUBLIC}"
}


delete_iface() {

    local iface="$1"

    if iface_exists "$iface"; then
        ip link set "$iface" down 2>/dev/null || true
        ip tunnel del "$iface" 2>/dev/null || true
    fi
}


# ============================================================
# IPV4 FORWARDING
# ============================================================

enable_forwarding() {

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    cat > "$SYSCTL_FORWARD" <<EOF
net.ipv4.ip_forward=1
EOF
}


# ============================================================
# PORT RULE STORAGE
# ============================================================

rule_exists() {

    local id="$1"
    local proto="$2"
    local public_port="$3"
    local destination_port="$4"

    grep -Fxq \
        "${proto}|${public_port}|${destination_port}" \
        "$PORTS/${id}.rules" 2>/dev/null
}


port_conflict() {

    local id="$1"
    local proto="$2"
    local public_port="$3"

    local file
    local p a b c

    for file in "$PORTS"/*.rules; do

        [[ -f "$file" ]] || continue

        [[ "$file" == "$PORTS/${id}.rules" ]] && continue

        while IFS='|' read -r a b c; do

            [[ "$a" == "$proto" &&
               "$b" == "$public_port" ]] &&
                return 0

        done < "$file"
    done

    return 1
}


# ============================================================
# PORT RULE REMOVAL
# ============================================================

flush_port_rules() {

    local id="$1"

    load_cfg "$id" || return 0

    local file="$PORTS/${id}.rules"
    local wan

    [[ -f "$file" ]] || return 0

    wan="$(wan_iface)"

    [[ -n "$wan" ]] || return 0


    local proto
    local public_port
    local destination_port


    while IFS='|' read -r \
        proto \
        public_port \
        destination_port
    do

        [[ -z "$proto" ]] && continue
        [[ "$proto" == \#* ]] && continue


        delete_rule \
            -t nat \
            -D PREROUTING \
            -i "$wan" \
            -p "$proto" \
            -d "$LOCAL_PUBLIC" \
            --dport "$public_port" \
            -m comment \
            --comment "PICASO PF $id" \
            -j DNAT \
            --to-destination \
            "${REMOTE_TUNNEL}:${destination_port}"


        delete_rule \
            -D FORWARD \
            -i "$wan" \
            -o "$INTERFACE" \
            -p "$proto" \
            -d "$REMOTE_TUNNEL" \
            --dport "$destination_port" \
            -m conntrack \
            --ctstate NEW,ESTABLISHED,RELATED \
            -m comment \
            --comment "PICASO PF $id" \
            -j ACCEPT


        delete_rule \
            -D FORWARD \
            -i "$INTERFACE" \
            -o "$wan" \
            -s "$REMOTE_TUNNEL" \
            -m conntrack \
            --ctstate ESTABLISHED,RELATED \
            -m comment \
            --comment "PICASO PF $id" \
            -j ACCEPT


        delete_rule \
            -t nat \
            -D POSTROUTING \
            -o "$INTERFACE" \
            -p "$proto" \
            -d "$REMOTE_TUNNEL" \
            --dport "$destination_port" \
            -m comment \
            --comment "PICASO PF $id" \
            -j MASQUERADE

    done < "$file"
}


# ============================================================
# PORT RULE APPLICATION
# ============================================================

apply_ports() {

    local id="$1"

    load_cfg "$id" || return 0

    [[ "$ROLE" == "IRAN" ]] || return 0

    local file="$PORTS/${id}.rules"
    local wan

    [[ -f "$file" ]] || return 0

    wan="$(wan_iface)"

    [[ -n "$wan" ]] ||
        die "Could not detect WAN interface."


    enable_forwarding


    local proto
    local public_port
    local destination_port


    while IFS='|' read -r \
        proto \
        public_port \
        destination_port
    do

        [[ -z "$proto" ]] && continue
        [[ "$proto" == \#* ]] && continue


        if ! iptables -t nat -C PREROUTING \
            -i "$wan" \
            -p "$proto" \
            -d "$LOCAL_PUBLIC" \
            --dport "$public_port" \
            -m comment \
            --comment "PICASO PF $id" \
            -j DNAT \
            --to-destination \
            "${REMOTE_TUNNEL}:${destination_port}" \
            2>/dev/null
        then

            iptables -t nat -A PREROUTING \
                -i "$wan" \
                -p "$proto" \
                -d "$LOCAL_PUBLIC" \
                --dport "$public_port" \
                -m comment \
                --comment "PICASO PF $id" \
                -j DNAT \
                --to-destination \
                "${REMOTE_TUNNEL}:${destination_port}"
        fi


        if ! iptables -C FORWARD \
            -i "$wan" \
            -o "$INTERFACE" \
            -p "$proto" \
            -d "$REMOTE_TUNNEL" \
            --dport "$destination_port" \
            -m conntrack \
            --ctstate NEW,ESTABLISHED,RELATED \
            -m comment \
            --comment "PICASO PF $id" \
            -j ACCEPT \
            2>/dev/null
        then

            iptables -A FORWARD \
                -i "$wan" \
                -o "$INTERFACE" \
                -p "$proto" \
                -d "$REMOTE_TUNNEL" \
                --dport "$destination_port" \
                -m conntrack \
                --ctstate NEW,ESTABLISHED,RELATED \
                -m comment \
                --comment "PICASO PF $id" \
                -j ACCEPT
        fi


        if ! iptables -C FORWARD \
            -i "$INTERFACE" \
            -o "$wan" \
            -s "$REMOTE_TUNNEL" \
            -m conntrack \
            --ctstate ESTABLISHED,RELATED \
            -m comment \
            --comment "PICASO PF $id" \
            -j ACCEPT \
            2>/dev/null
        then

            iptables -A FORWARD \
                -i "$INTERFACE" \
                -o "$wan" \
                -s "$REMOTE_TUNNEL" \
                -m conntrack \
                --ctstate ESTABLISHED,RELATED \
                -m comment \
                --comment "PICASO PF $id" \
                -j ACCEPT
        fi


        if ! iptables -t nat -C POSTROUTING \
            -o "$INTERFACE" \
            -p "$proto" \
            -d "$REMOTE_TUNNEL" \
            --dport "$destination_port" \
            -m comment \
            --comment "PICASO PF $id" \
            -j MASQUERADE \
            2>/dev/null
        then

            iptables -t nat -A POSTROUTING \
                -o "$INTERFACE" \
                -p "$proto" \
                -d "$REMOTE_TUNNEL" \
                --dport "$destination_port" \
                -m comment \
                --comment "PICASO PF $id" \
                -j MASQUERADE
        fi


        log "Port forwarding: tunnel=$id ${proto} ${public_port}->${destination_port}"

    done < "$file"
}


# ============================================================
# ADD / REMOVE PORT
# ============================================================

add_port() {

    local id="$1"
    local proto="$2"
    local public_port="$3"
    local destination_port="$4"

    load_cfg "$id" ||
        die "Tunnel not found."

    [[ "$ROLE" == "IRAN" ]] ||
        die "Port forwarding is configured on the IRAN server."

    valid_proto "$proto" ||
        die "Invalid protocol."

    valid_port "$public_port" ||
        die "Invalid public port."

    valid_port "$destination_port" ||
        die "Invalid destination port."


    if rule_exists \
        "$id" \
        "$proto" \
        "$public_port" \
        "$destination_port"
    then

        warn "This forwarding rule already exists."
        return
    fi


    if port_conflict \
        "$id" \
        "$proto" \
        "$public_port"
    then

        die "Public port ${public_port}/${proto} is already used by another PICASO tunnel."
    fi


    printf '%s|%s|%s\n' \
        "$proto" \
        "$public_port" \
        "$destination_port" \
        >> "$PORTS/${id}.rules"


    apply_ports "$id"

    log "Port forwarding added: tunnel=$id ${proto} ${public_port}->${destination_port}"

    ok "Forwarding added."
}


remove_port() {

    local id="$1"
    local proto="$2"
    local public_port="$3"
    local destination_port="$4"

    [[ -f "$PORTS/${id}.rules" ]] || return 0


    sed -i \
        "\#^${proto}|${public_port}|${destination_port}$#d" \
        "$PORTS/${id}.rules"


    flush_port_rules "$id"
    apply_ports "$id"


    log "Port forwarding removed: tunnel=$id ${proto} ${public_port}->${destination_port}"

    ok "Forwarding removed."
}


# ============================================================
# TUNNEL CONTROL
# ============================================================

start_tunnel() {

    local id="$1"

    load_cfg "$id" ||
        die "Tunnel not found."


    sed -i \
        's/^ENABLED=.*/ENABLED=1/' \
        "$TUNNELS/${id}.conf"


    create_gre "$id"


    if [[ "$ROLE" == "IRAN" ]]; then
        apply_ports "$id"
    fi


    log "Tunnel $id started."

    ok "Tunnel $id started."
}


stop_tunnel() {

    local id="$1"

    load_cfg "$id" ||
        die "Tunnel not found."


    flush_port_rules "$id"

    gre_fw_del \
        "$REMOTE_PUBLIC" \
        "$INTERFACE"

    delete_iface "$INTERFACE"


    sed -i \
        's/^ENABLED=.*/ENABLED=0/' \
        "$TUNNELS/${id}.conf"


    log "Tunnel $id stopped."

    ok "Tunnel $id stopped."
}


restart_tunnel() {

    local id="$1"

    stop_tunnel "$id"

    sleep 1

    start_tunnel "$id"
}


delete_tunnel() {

    local id="$1"

    load_cfg "$id" ||
        die "Tunnel not found."


    echo
    warn "This permanently deletes tunnel $id."
    echo

    read -r -p "Type DELETE to continue: " confirm

    [[ "$confirm" == "DELETE" ]] ||
    {
        warn "Cancelled."
        return
    }


    flush_port_rules "$id"

    gre_fw_del \
        "$REMOTE_PUBLIC" \
        "$INTERFACE"

    delete_iface "$INTERFACE"


    rm -f \
        "$TUNNELS/${id}.conf" \
        "$PORTS/${id}.rules"


    log "Tunnel $id deleted."

    ok "Tunnel $id deleted."
}


# ============================================================
# STATUS
# ============================================================

status_tunnel() {

    local id="$1"

    load_cfg "$id" || return 1


    if ! iface_exists "$INTERFACE"; then

        if [[ "${ENABLED:-0}" == "1" ]]; then
            echo "MISSING"
        else
            echo "STOPPED"
        fi

        return
    fi


    if ping \
        -I "$INTERFACE" \
        -c 1 \
        -W 1 \
        "$REMOTE_TUNNEL" \
        >/dev/null 2>&1
    then

        echo "UP"

    else

        echo "DEGRADED"

    fi
}


# ============================================================
# LIST
# ============================================================

list_tunnels() {

    local file

    printf '\n'
    printf '%-4s %-10s %-8s %-16s %-16s %s\n' \
        "ID" \
        "STATUS" \
        "ROLE" \
        "LOCAL_PUBLIC" \
        "REMOTE_PUBLIC" \
        "INTERFACE"

    for file in "$TUNNELS"/*.conf; do

        [[ -f "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"

        printf '%-4s %-10s %-8s %-16s %-16s %s\n' \
            "$ID" \
            "$(status_tunnel "$ID")" \
            "$ROLE" \
            "$LOCAL_PUBLIC" \
            "$REMOTE_PUBLIC" \
            "$INTERFACE"
    done

    echo
}


# ============================================================
# TEST
# ============================================================

test_tunnel() {

    local id="$1"

    load_cfg "$id" ||
        die "Tunnel not found."


    echo
    echo "========================================"
    echo " PICASO Tunnel Test - $id"
    echo "========================================"
    echo


    echo "Interface:"
    ip -d link show "$INTERFACE" ||
        return 0


    echo
    echo "Addresses:"
    ip addr show "$INTERFACE"


    echo
    echo "Route:"
    ip route get "$REMOTE_TUNNEL" || true


    echo
    echo "Ping:"
    ping \
        -I "$INTERFACE" \
        -c 3 \
        -W 2 \
        "$REMOTE_TUNNEL" || true


    echo
    echo "Traffic:"
    ip -s link show "$INTERFACE"


    echo
    echo "GRE capture:"
    echo "tcpdump -ni any 'ip proto 47'"
}


# ============================================================
# DETAILS
# ============================================================

details() {

    local id="$1"

    load_cfg "$id" ||
        die "Tunnel not found."


    echo
    echo "========================================"
    echo " Tunnel $ID"
    echo "========================================"

    echo "Role          : $ROLE"
    echo "Interface     : $INTERFACE"
    echo "Local public  : $LOCAL_PUBLIC"
    echo "Remote public : $REMOTE_PUBLIC"
    echo "Local GRE     : $LOCAL_TUNNEL"
    echo "Remote GRE    : $REMOTE_TUNNEL"
    echo "Subnet        : $SUBNET"
    echo "MTU           : $MTU"
    echo "Enabled       : $ENABLED"

    echo
    echo "Port forwarding:"

    if [[ -s "$PORTS/${id}.rules" ]]; then

        cat "$PORTS/${id}.rules"

    else

        echo "None"

    fi

    echo
}


# ============================================================
# TRAFFIC
# ============================================================

show_traffic() {

    local id="$1"

    load_cfg "$id" ||
        die "Tunnel not found."

    ip -s link show "$INTERFACE" || true
}


# ============================================================
# REPAIR
# ============================================================

repair() {

    local file

    for file in "$TUNNELS"/*.conf; do

        [[ -f "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"

        [[ "${ENABLED:-0}" == "1" ]] || continue


        info "Repairing tunnel $ID..."

        create_gre "$ID"


        if [[ "$ROLE" == "IRAN" ]]; then

            flush_port_rules "$ID"
            apply_ports "$ID"

        fi

    done


    ok "Repair completed."

    log "Repair completed."
}


restore_all() {

    init

    repair
}


# ============================================================
# PORT FORWARD MENU
# ============================================================

port_menu() {

    local id="$1"
    local choice
    local proto
    local public_port
    local destination_port


    load_cfg "$id" ||
        die "Tunnel not found."


    if [[ "$ROLE" != "IRAN" ]]; then

        warn "Port forwarding must be configured on the IRAN server."

        pause

        return
    fi


    while true; do

        clear_screen

        echo "========================================"
        echo " PICASO Port Forwarding"
        echo " Tunnel: $id"
        echo "========================================"

        echo
        echo "Foreign GRE IP: $REMOTE_TUNNEL"
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

                read -r \
                    -p "Protocol (tcp/udp): " \
                    proto

                read -r \
                    -p "Iran public port: " \
                    public_port

                read -r \
                    -p "Foreign destination port: " \
                    destination_port


                add_port \
                    "$id" \
                    "$proto" \
                    "$public_port" \
                    "$destination_port"

                pause
                ;;


            2)

                read -r \
                    -p "Protocol (tcp/udp): " \
                    proto

                read -r \
                    -p "Iran public port: " \
                    public_port

                read -r \
                    -p "Foreign destination port: " \
                    destination_port


                remove_port \
                    "$id" \
                    "$proto" \
                    "$public_port" \
                    "$destination_port"

                pause
                ;;


            3)

                echo

                if [[ -s "$PORTS/${id}.rules" ]]; then
                    cat "$PORTS/${id}.rules"
                else
                    echo "No forwarding rules."
                fi

                pause
                ;;


            4)

                flush_port_rules "$id"
                apply_ports "$id"

                ok "Rules re-applied."

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
# MANAGE TUNNEL
# ============================================================

manage() {

    local id="$1"
    local choice


    while true; do

        clear_screen

        details "$id"

        echo
        echo "1) Start"
        echo "2) Stop"
        echo "3) Restart"
        echo "4) Test"
        echo "5) Traffic"
        echo "6) Port Forwarding"
        echo "7) Delete"
        echo "0) Back"
        echo

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
                show_traffic "$id"
                pause
                ;;


            6)
                port_menu "$id"
                ;;


            7)
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
# ADD NEW TUNNEL
# ============================================================

add_tunnel() {

    local role_choice
    local role

    local detected
    local local_public
    local remote_public

    local id
    local iface
    local subnet
    local local_tun
    local remote_tun

    local mtu=1476

    local file


    clear_screen

    echo "========================================"
    echo " PICASO - Add New Connection"
    echo "========================================"

    echo
    echo "1) IRAN"
    echo "2) FOREIGN"
    echo


    read -r -p "Server role: " role_choice


    case "$role_choice" in

        1)
            role="IRAN"
            ;;

        2)
            role="FOREIGN"
            ;;

        *)
            die "Invalid role."
            ;;
    esac


    detected="$(detect_public_ip || true)"

    echo

    if [[ -n "$detected" ]]; then
        echo "Detected local IPv4: $detected"
    else
        warn "Could not automatically detect local IPv4."
    fi


    read -r \
        -p "Local public IPv4 [${detected}]: " \
        local_public


    local_public="${local_public:-$detected}"


    valid_ipv4 "$local_public" ||
        die "Invalid local public IPv4."


    local_ipv4_exists "$local_public" ||
        die "Local public IPv4 $local_public is not assigned to this server."


    read -r \
        -p "Remote server public IPv4: " \
        remote_public


    valid_ipv4 "$remote_public" ||
        die "Invalid remote public IPv4."


    [[ "$local_public" != "$remote_public" ]] ||
        die "Local and remote public IP cannot be identical."


    # --------------------------------------------------------
    # ID
    # --------------------------------------------------------

    if [[ "$role" == "FOREIGN" ]]; then

        echo
        echo "Enter the SAME Tunnel ID that was created on Iran."

        read -r \
            -p "Iran tunnel ID: " \
            id

        reserve_manual_id "$id"

    else

        id="$(next_id)"

    fi


    # --------------------------------------------------------
    # Duplicate endpoint protection
    # --------------------------------------------------------

    for file in "$TUNNELS"/*.conf; do

        [[ -f "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"


        if [[ "$LOCAL_PUBLIC" == "$local_public" &&
              "$REMOTE_PUBLIC" == "$remote_public" ]]
        then

            die "This exact tunnel already exists."
        fi


        if [[ "$REMOTE_PUBLIC" == "$remote_public" ]]; then

            die "Remote public IP $remote_public is already used by tunnel $ID. Standard GRE without keys requires a unique remote public endpoint."
        fi

    done


    # --------------------------------------------------------
    # Interface / subnet
    # --------------------------------------------------------

    iface="picaso-gre${id}"

    subnet="$(subnet_for_id "$id")"


    if [[ "$role" == "IRAN" ]]; then

        # IRAN = .2
        # FOREIGN = .1

        local_tun="$(ip_plus "$subnet" 2)"
        remote_tun="$(ip_plus "$subnet" 1)"

    else

        # FOREIGN = .1
        # IRAN = .2

        local_tun="$(ip_plus "$subnet" 1)"
        remote_tun="$(ip_plus "$subnet" 2)"

    fi


    echo
    echo "----------------------------------------"
    echo "Tunnel ID       : $id"
    echo "Role            : $role"
    echo "Interface       : $iface"
    echo "Local public    : $local_public"
    echo "Remote public   : $remote_public"
    echo "GRE subnet      : $subnet"
    echo "Local GRE IP    : $local_tun"
    echo "Remote GRE IP   : $remote_tun"
    echo "MTU             : $mtu"
    echo "----------------------------------------"
    echo


    read -r \
        -p "Create this tunnel? [y/N]: " \
        confirm


    [[ "$confirm" =~ ^[Yy]$ ]] ||
    {
        warn "Cancelled."
        return
    }


    save_cfg \
        "$id" \
        "$role" \
        "$local_public" \
        "$remote_public" \
        "$iface" \
        "$local_tun" \
        "$remote_tun" \
        "$subnet" \
        "$mtu"


    : > "$PORTS/${id}.rules"


    create_gre "$id"


    if [[ "$role" == "IRAN" ]]; then
        enable_forwarding
    fi


    ok "Tunnel $id created successfully."

    echo
    echo "GRE:"
    echo "  Local  : $local_tun"
    echo "  Remote : $remote_tun"

    echo
    echo "For port forwarding configure it on IRAN."

    echo
    echo "Example:"
    echo "  TCP 443 -> 443"

    echo
    echo "Client connects to:"
    echo "  ${local_public}:443"

    echo
    echo "Traffic:"
    echo "  Client"
    echo "    -> ${local_public}:443"
    echo "    -> ${remote_tun}:443"
    echo "    -> Foreign Xray"

    echo

    log "Tunnel $id created."
}


# ============================================================
# OPTIMIZATION
# ============================================================

apply_bbr() {

    if ! grep -qw \
        bbr \
        /proc/sys/net/ipv4/tcp_available_congestion_control \
        2>/dev/null
    then

        warn "BBR is not available in the current kernel."

        return 1
    fi


    cat > "$SYSCTL_BBR" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF


    sysctl --system >/dev/null


    ok "BBR configuration applied."
}


apply_network_optimization() {

    cat > "$SYSCTL_NET" <<EOF
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


    sysctl --system >/dev/null


    ok "Network optimization applied."
}


optimization_menu() {

    local choice


    while true; do

        clear_screen

        echo "========================================"
        echo " PICASO - Server Optimization"
        echo "========================================"

        echo
        echo "1) Enable BBR"
        echo "2) Optimize TCP / Network"
        echo "3) Enable IPv4 Forwarding"
        echo "4) Apply All"
        echo "5) Show Current Settings"
        echo "0) Back"
        echo


        read -r -p "Select: " choice


        case "$choice" in

            1)
                apply_bbr || true
                pause
                ;;


            2)
                apply_network_optimization
                pause
                ;;


            3)
                enable_forwarding
                ok "IPv4 forwarding enabled."
                pause
                ;;


            4)
                apply_bbr || true
                apply_network_optimization
                enable_forwarding
                ok "All recommended settings applied."
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
# SYSTEMD SCRIPTS
# ============================================================

write_services() {

    cat > "$RESTORE" <<'EOF'
#!/usr/bin/env bash

set -u

sleep 2

if [[ -x /usr/local/bin/picaso ]]; then
    /usr/local/bin/picaso --restore
fi
EOF

    chmod 755 "$RESTORE"


    cat > "$MONITOR" <<'EOF'
#!/usr/bin/env bash

set -u

BASE="/etc/picaso"
TUNNELS="$BASE/tunnels"
LOG="/var/log/picaso.log"

declare -A LAST_STATE


while true; do

    for file in "$TUNNELS"/*.conf; do

        [[ -f "$file" ]] || continue

        unset \
            ID \
            ROLE \
            INTERFACE \
            REMOTE_TUNNEL \
            ENABLED

        # shellcheck disable=SC1090
        source "$file"


        [[ "${ENABLED:-0}" == "1" ]] || continue


        state="MISSING"


        if ip link show "$INTERFACE" >/dev/null 2>&1; then

            if ping \
                -I "$INTERFACE" \
                -c 1 \
                -W 1 \
                "$REMOTE_TUNNEL" \
                >/dev/null 2>&1
            then

                state="UP"

            else

                state="DEGRADED"

            fi
        fi


        previous="${LAST_STATE[$ID]:-UNKNOWN}"


        if [[ "$state" != "$previous" ]]; then

            printf '[%s] Tunnel %s state: %s -> %s\n' \
                "$(date '+%F %T')" \
                "$ID" \
                "$previous" \
                "$state" \
                >> "$LOG"

            LAST_STATE[$ID]="$state"
        fi

    done


    sleep 30

done
EOF


    chmod 755 "$MONITOR"


    # --------------------------------------------------------
    # Restore service
    # --------------------------------------------------------

    cat > "/etc/systemd/system/$RESTORE_UNIT" <<EOF
[Unit]
Description=PICASO GRE Restore
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RESTORE

[Install]
WantedBy=multi-user.target
EOF


    # --------------------------------------------------------
    # Monitor service
    # --------------------------------------------------------

    cat > "/etc/systemd/system/$MONITOR_UNIT" <<EOF
[Unit]
Description=PICASO GRE Monitor
Wants=network-online.target $RESTORE_UNIT
After=network-online.target $RESTORE_UNIT

[Service]
Type=simple
ExecStart=$MONITOR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


    systemctl daemon-reload

    systemctl enable \
        "$RESTORE_UNIT" \
        "$MONITOR_UNIT" \
        >/dev/null


    systemctl restart "$MONITOR_UNIT" \
        >/dev/null 2>&1 || true
}


# ============================================================
# UNINSTALL
# ============================================================

uninstall() {

    clear_screen

    echo "========================================"
    echo " PICASO COMPLETE UNINSTALL"
    echo "========================================"

    echo
    echo "PICASO will remove:"
    echo
    echo " - PICASO GRE interfaces"
    echo " - PICASO port-forward rules"
    echo " - PICASO GRE firewall rules"
    echo " - PICASO systemd services"
    echo " - PICASO configuration"
    echo " - PICASO logs"
    echo " - PICASO command"
    echo
    echo "PICASO will NOT:"
    echo
    echo " - Flush all iptables"
    echo " - Delete gre0"
    echo " - Delete unrelated firewall rules"
    echo


    read -r \
        -p "Type DELETE to continue: " \
        confirm


    [[ "$confirm" == "DELETE" ]] ||
    {
        warn "Cancelled."
        return
    }


    systemctl disable --now \
        "$MONITOR_UNIT" \
        "$RESTORE_UNIT" \
        >/dev/null 2>&1 || true


    local file

    for file in "$TUNNELS"/*.conf; do

        [[ -f "$file" ]] || continue

        # shellcheck disable=SC1090
        source "$file"

        flush_port_rules "$ID" || true

        gre_fw_del \
            "$REMOTE_PUBLIC" \
            "$INTERFACE" \
            || true

        delete_iface \
            "$INTERFACE" \
            || true

    done


    rm -f \
        "/etc/systemd/system/$RESTORE_UNIT" \
        "/etc/systemd/system/$MONITOR_UNIT" \
        "$RESTORE" \
        "$MONITOR" \
        "$BIN" \
        "$SYSCTL_FORWARD" \
        "$SYSCTL_BBR" \
        "$SYSCTL_NET"


    systemctl daemon-reload


    rm -rf "$BASE"

    rm -f "$LOG"


    ok "PICASO completely removed."

    echo
    echo "gre0 and unrelated iptables rules were left untouched."

    exit 0
}


# ============================================================
# MAIN
# ============================================================

main() {

    require_root

    install_missing

    require_commands

    init


    # --------------------------------------------------------
    # Restore mode
    # --------------------------------------------------------

    if [[ "${1:-}" == "--restore" ]]; then

        restore_all

        exit 0
    fi


    # --------------------------------------------------------
    # Install manager
    # --------------------------------------------------------

    if [[ "$0" != "$BIN" ]]; then

        if cp "$0" "$BIN" 2>/dev/null; then

            chmod 755 "$BIN"

        else

            warn "Could not copy installer to $BIN."
            warn "Current interactive session will continue."

        fi
    fi


    # --------------------------------------------------------
    # Systemd
    # --------------------------------------------------------

    write_services


    # --------------------------------------------------------
    # Main menu
    # --------------------------------------------------------

    while true; do

        clear_screen

        echo -e "${C}"
        echo "=============================================="
        echo "                 PICASO"
        echo "          Multi GRE Tunnel Manager"
        echo "                 v${VERSION}"
        echo "=============================================="
        echo -e "${X}"


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


        read -r \
            -p "Select: " \
            choice


        case "$choice" in

            1)

                add_tunnel
                pause
                ;;


            2)

                read -r \
                    -p "Tunnel ID: " \
                    id


                if valid_id "$id" &&
                   [[ -f "$TUNNELS/${id}.conf" ]]
                then

                    manage "$id"

                else

                    warn "Tunnel $id not found."

                    pause

                fi

                ;;


            3)

                clear_screen

                list_tunnels

                pause
                ;;


            4)

                clear_screen

                repair

                pause
                ;;


            5)

                optimization_menu

                ;;


            6)

                clear_screen

                echo "========================================"
                echo " PICASO Logs"
                echo "========================================"
                echo

                if [[ -f "$LOG" ]]; then
                    tail -n 100 "$LOG"
                else
                    echo "No logs."
                fi

                pause
                ;;


            7)

                uninstall

                ;;


            0)

                clear_screen

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


main "$@"
