#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — VPN module (WireGuard)
#
#  Network 10.8.0.0/24: the server is 10.8.0.1, client number N gets
#  10.8.0.(N+1) and the public port 60000+N, forwarded to it in TCP and UDP
#  (handy for a torrent client at home behind the VPN).
#
#  Everything is generated again from /etc/seedtunnel/vpn/ (« vpn_apply »):
#    server.key / server.pub      keys of the server
#    clients/<name>.env           number and keys of a client
#    clients/<name>.conf          file to import into the WireGuard app
#    nat.nft                      NAT rules, loaded by systemd when wg0 starts
#                                 (wg-quick@wg0.service.d/seedtunnel.conf)
#  vpn_apply only changes what needs to change: it can safely run again.
# =============================================================================

VPN_INTERFACE="wg0"
VPN_SUBNET="10.8.0"
# 10.8.0.2 → 10.8.0.254
VPN_MAX_CLIENTS=253
# client number N gets the port 60000+N
VPN_FORWARDED_PORT_BASE=60000
# White margin of the QR codes, in squares: 2 rather than the 4 of the
# standard (read by the phones), 4 columns and 2 lines less
VPN_QR_MARGIN=2
VPN_STATE_DIR="$APP_STATE_DIR/vpn"
VPN_CONF_FILE="$APP_STATE_DIR/vpn.conf"
VPN_CLIENTS_DIR="$VPN_STATE_DIR/clients"
VPN_NAT_RULES="$VPN_STATE_DIR/nat.nft"
VPN_SYSCTL_FILE="/etc/sysctl.d/90-seedtunnel-vpn.conf"
WIREGUARD_CONF="/etc/wireguard/$VPN_INTERFACE.conf"
# Addition to the service of WireGuard: it loads the NAT rules (see below)
VPN_SYSTEMD_DROPIN="/etc/systemd/system/wg-quick@$VPN_INTERFACE.service.d/seedtunnel.conf"

vpn_load() {
    VPN_PORT=51820
    VPN_PUBLIC_ADDRESS=""
    VPN_DNS="9.9.9.9, 149.112.112.112"
    VPN_OUT_INTERFACE=""
    state_read "$VPN_CONF_FILE"
}

vpn_save() { state_write "$VPN_CONF_FILE" VPN_PORT VPN_PUBLIC_ADDRESS VPN_DNS VPN_OUT_INTERFACE; }

vpn_installed() { [[ -f $VPN_CONF_FILE ]]; }

vpn_require_installed() {
    vpn_installed || die 'The VPN is not installed:  seedtunnel vpn install'
}

vpn_client_names() {
    local file
    for file in "$VPN_CLIENTS_DIR"/*.env; do
        [[ -e $file ]] || continue
        file=${file##*/}
        printf '%s\n' "${file%.env}"
    done
}

vpn_count_clients() {
    local count=0 file
    for file in "$VPN_CLIENTS_DIR"/*.env; do
        if [[ -e $file ]]; then count=$((count + 1)); fi
    done
    printf '%s' "$count"
}

# Connected clients: last handshake less than 3 minutes ago (WireGuard
# renews it every 2 minutes while the tunnel is in use)
vpn_connected_count() {
    local now count=0 _key handshake
    if systemctl is-active --quiet "wg-quick@$VPN_INTERFACE"; then
        now=$(date +%s)
        while read -r _key handshake; do
            if [[ $handshake =~ ^[0-9]+$ ]] && ((handshake > 0 && now - handshake < 180)); then
                count=$((count + 1))
            fi
        done < <(wg show "$VPN_INTERFACE" latest-handshakes 2>/dev/null || true)
    fi
    printf '%s' "$count"
}

# 15 characters at most: on Linux the file name becomes the interface name
vpn_is_valid_client_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,15}$ ]]; }

vpn_require_client() {
    vpn_is_valid_client_name "$1" || die 'Invalid client name: "%s".' "$1"
    [[ -e $VPN_CLIENTS_DIR/$1.env ]] || die 'Client "%s" not found (seedtunnel vpn list).' "$1"
}

# The DNS servers offered to the clients, in the order of the menu
VPN_DNS_SERVICES=(quad9 cloudflare dns4eu adguard)

# quad9 | cloudflare | dns4eu | adguard | IP addresses separated by commas
vpn_dns_value() {
    case ${1,,} in
        quad9 | "") printf '9.9.9.9, 149.112.112.112' ;;
        cloudflare) printf '1.1.1.1, 1.0.0.1' ;;
        # « Protective » resolver of the European Union
        dns4eu) printf '86.54.11.1, 86.54.11.201' ;;
        adguard) printf '94.140.14.14, 94.140.15.15' ;;
        *) printf '%s' "$1" ;;
    esac
}

# vpn_dns_service ADDRESSES — the key of the service of these addresses (quad9…),
# nothing for addresses typed by hand
vpn_dns_service() {
    local key
    for key in "${VPN_DNS_SERVICES[@]}"; do
        if [[ $(vpn_dns_value "$key" | tr -d '[:space:]') == "$(tr -d '[:space:]' <<<"$1")" ]]; then
            printf '%s' "$key"
            return 0
        fi
    done
}

# vpn_dns_label ADDRESSES — « Quad9 · 9.9.9.9, 149.112.112.112 », or the
# addresses alone (« · »: where a narrow screen goes on to the next line)
vpn_dns_label() {
    case $(vpn_dns_service "$1") in
        quad9) printf 'Quad9 · %s' "$1" ;;
        cloudflare) printf 'Cloudflare · %s' "$1" ;;
        dns4eu) printf 'DNS4EU · %s' "$1" ;;
        adguard) printf 'AdGuard · %s' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# DNS servers of the clients: IPv4 or IPv6 addresses separated by commas,
# on one line (« read » stops at the first one: a second line would go into
# the files of the clients). Spaces around the addresses only: « 9.9. 9.9 »
# is refused. « read » would drop a comma at the end: refused before.
vpn_is_valid_dns() {
    local entry count=0 compact=${1//[[:space:]]/}
    local -a entries
    [[ $1 != *[!0-9A-Fa-f.:,\ ]* ]] || return 1
    [[ $compact != ,* && $compact != *, ]] || return 1
    IFS=, read -r -a entries <<<"$1"
    for entry in "${entries[@]}"; do
        entry=${entry#"${entry%%[! ]*}"}
        entry=${entry%"${entry##*[! ]}"}
        [[ -n $entry ]] || return 1
        if ! is_ipv4 "$entry" && ! is_ipv6 "$entry"; then return 1; fi
        count=$((count + 1))
    done
    ((count > 0))
}

# vpn_dns_normalize ADDRESSES — the addresses (checked) as they are saved:
# « 9.9.9.9, 1.1.1.1 »
vpn_dns_normalize() {
    local entry joined=""
    local -a entries
    IFS=, read -r -a entries <<<"$1"
    for entry in "${entries[@]}"; do
        entry=${entry//[[:space:]]/}
        joined+="${joined:+, }$entry"
    done
    printf '%s' "$joined"
}

# Public address of the server, written in the files of the clients: an IPv4
# or IPv6 address, or a domain name (capital letters allowed)
vpn_is_valid_address() { is_ipv4 "$1" || is_ipv6 "$1" || seedbox_is_valid_domain "${1,,}"; }

# Is the UDP port free (or already ours)?
vpn_port_is_free() {
    local current
    current=$(wg show "$VPN_INTERFACE" listen-port 2>/dev/null || true)
    [[ $1 == "$current" ]] && return 0
    ! port_in_use udp "$1"
}

# Can the kernel create a WireGuard interface? (fails in some OpenVZ/LXC
# containers, like the TUN/TAP module used to)
vpn_check_kernel() {
    if ip link show "$VPN_INTERFACE" &>/dev/null; then return 0; fi
    # left by a check cut short: « add » would fail on it
    ip link del dev st-wgtest &>/dev/null || true
    if ! ip link add dev st-wgtest type wireguard 2>/dev/null; then
        die 'The kernel cannot create a WireGuard interface.\n  On a container VPS (OpenVZ, LXC), ask the provider to enable WireGuard,\n  or choose a KVM plan.'
    fi
    ip link del dev st-wgtest
}

# --- File generation (on standard output) -----------------------------------------

vpn_generate_client_conf() {
    local name=$1 CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY CLIENT_PRIVATE_KEY address
    # shellcheck source=/dev/null
    . "$VPN_CLIENTS_DIR/$name.env"
    address=$VPN_PUBLIC_ADDRESS
    # IPv6 address → between brackets
    if [[ $address == *:* ]]; then address="[$address]"; fi
    cat <<EOF
# seedtunnel — client "$name" — IP $VPN_SUBNET.$((CLIENT_NUMBER + 1)) — open port $((VPN_FORWARDED_PORT_BASE + CLIENT_NUMBER))
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $VPN_SUBNET.$((CLIENT_NUMBER + 1))/32
DNS = $VPN_DNS

[Peer]
PublicKey = $(<"$VPN_STATE_DIR/server.pub")
PresharedKey = $CLIENT_PRESHARED_KEY
Endpoint = $address:$VPN_PORT
# ::/0 also sends IPv6 into the tunnel (where it is blocked): no IPv6 leak
AllowedIPs = 0.0.0.0/0, ::/0
# Keeps the tunnel open behind a home router: needed for the open port
PersistentKeepalive = 25
EOF
}

vpn_generate_server_conf() {
    local file name key="" CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY CLIENT_PRIVATE_KEY
    # its first line only: a second one would be read by wg-quick (PostUp…)
    IFS= read -r key <"$VPN_STATE_DIR/server.key" || true
    cat <<EOF
# Written by seedtunnel — use the menu rather than editing this file.
[Interface]
Address = $VPN_SUBNET.1/24
ListenPort = $VPN_PORT
PrivateKey = $key
EOF
    for file in "$VPN_CLIENTS_DIR"/*.env; do
        [[ -e $file ]] || continue
        name=${file##*/}
        name=${name%.env}
        # shellcheck source=/dev/null
        . "$file"
        cat <<EOF || return 1

# client: $name
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = $VPN_SUBNET.$((CLIENT_NUMBER + 1))/32
EOF
    done
}

# The NAT rules are loaded by systemd, right after wg-quick has started wg0,
# and removed when it stops. Not by a PostUp line of wg0.conf: on Ubuntu 26.04,
# AppArmor confines the nft that wg-quick runs, and it may read no file (the
# VPN did not start). The « - » keeps the stop going if the table is gone.
vpn_generate_systemd_dropin() {
    cat <<EOF
# Written by seedtunnel: NAT rules of the VPN (way out to the Internet, open
# ports of the clients), loaded when $VPN_INTERFACE starts, removed when it stops.
[Service]
ExecStartPost=/usr/sbin/nft -f $VPN_NAT_RULES
ExecStopPost=-/usr/sbin/nft delete table ip seedtunnel
EOF
}

# « table / delete / table » replaces the table in one go, whether it exists or
# not, without touching the other rules of the system.
vpn_generate_nat_rules() {
    local file name CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY CLIENT_PRIVATE_KEY
    cat <<EOF
#!/usr/sbin/nft -f
# Written by seedtunnel — NAT of the VPN, loaded when $VPN_INTERFACE starts.
table ip seedtunnel
delete table ip seedtunnel
table ip seedtunnel {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF
    for file in "$VPN_CLIENTS_DIR"/*.env; do
        [[ -e $file ]] || continue
        name=${file##*/}
        name=${name%.env}
        # shellcheck source=/dev/null
        . "$file"
        printf '        # client "%s"\n' "$name"
        printf '        iifname "%s" meta l4proto { tcp, udp } th dport %s dnat to %s\n' \
            "$VPN_OUT_INTERFACE" "$((VPN_FORWARDED_PORT_BASE + CLIENT_NUMBER))" "$VPN_SUBNET.$((CLIENT_NUMBER + 1))" || return 1
    done
    cat <<EOF
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # clients go out to the Internet with the IP of the server
        ip saddr $VPN_SUBNET.0/24 oifname "$VPN_OUT_INTERFACE" masquerade
    }
}
EOF
}

# --- Applying ----------------------------------------------------------------------

# Applies the configuration live, without disconnecting the clients. Each step
# is checked: if WireGuard refuses the configuration, « run » shows « failed »
# with the error, instead of « ok ».
vpn_sync() {
    local stripped
    stripped=$(wg-quick strip "$VPN_INTERFACE") || return 1
    # the NAT rules are checked first: if nftables refuses them, the clients
    # are not changed either (never new clients without their open port)
    nft -c -f "$VPN_NAT_RULES" || return 1
    wg syncconf "$VPN_INTERFACE" <(printf '%s\n' "$stripped") || return 1
    nft -f "$VPN_NAT_RULES" || return 1
}

# Puts the server in the state described in /etc/seedtunnel (idempotent)
vpn_apply() {
    local interface name changed=0
    apt_install wireguard-tools qrencode
    install -d -m 700 "$VPN_STATE_DIR" "$VPN_CLIENTS_DIR" /etc/wireguard
    if [[ ! -s $VPN_STATE_DIR/server.key ]]; then
        (umask 077 && wg genkey >"$VPN_STATE_DIR/server.key")
    fi
    write_if_changed "$VPN_STATE_DIR/server.pub" 600 root:root wg pubkey <"$VPN_STATE_DIR/server.key" || true

    # the network interface may change (restore on another server)
    interface=$(default_interface)
    if [[ -n $interface ]]; then VPN_OUT_INTERFACE=$interface; fi
    [[ -n $VPN_OUT_INTERFACE ]] || die 'Main network interface not found (no default route?).'
    vpn_save
    # the port of the VPN is opened in the firewall before starting
    firewall_refresh

    # the server must forward the packets of the clients to the Internet
    if write_if_changed "$VPN_SYSCTL_FILE" 644 root:root \
        printf '%s\n' '# Written by seedtunnel: routing for the VPN clients' 'net.ipv4.ip_forward = 1' \
        || [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) != 1 ]]; then
        run 'Enabling IPv4 routing' sysctl -q -p "$VPN_SYSCTL_FILE"
    fi
    net_hardening_apply

    while IFS= read -r name; do
        write_if_changed "$VPN_CLIENTS_DIR/$name.conf" 600 root:root vpn_generate_client_conf "$name" || true
    done < <(vpn_client_names)
    if write_if_changed "$WIREGUARD_CONF" 600 root:root vpn_generate_server_conf; then changed=1; fi
    if write_if_changed "$VPN_NAT_RULES" 600 root:root vpn_generate_nat_rules; then changed=1; fi
    # before starting: systemd must know how to load the NAT rules
    install -d -m 755 "${VPN_SYSTEMD_DROPIN%/*}"
    if write_if_changed "$VPN_SYSTEMD_DROPIN" 644 root:root vpn_generate_systemd_dropin; then
        run 'Reloading systemd' systemctl daemon-reload
    fi
    vpn_reconcile "$changed"
}

# vpn_reconcile CHANGED — puts the running VPN in line with its files. Even when
# no file changed, the clients and the NAT are synchronized again (quietly): a
# change whose application failed earlier (a revoked client, for example) is
# applied at the next run instead of being forgotten. It cuts no connection.
vpn_reconcile() {
    local changed=$1 current_port
    if ! systemctl is-active --quiet "wg-quick@$VPN_INTERFACE"; then
        run 'Starting the VPN' systemctl enable --now "wg-quick@$VPN_INTERFACE"
        return 0
    fi
    current_port=$(wg show "$VPN_INTERFACE" listen-port 2>/dev/null || true)
    if [[ $current_port != "$VPN_PORT" ]]; then
        run 'Restarting the VPN (new port)' systemctl restart "wg-quick@$VPN_INTERFACE"
    elif ((changed)); then
        run 'Applying the configuration' vpn_sync
    elif ! vpn_sync >>"$APP_LOG" 2>&1; then
        die 'The running VPN does not match its configuration and cannot be updated (details in %s):  seedtunnel vpn restart' "$APP_LOG"
    fi
    # running: also at boot (it is not stopped for that)
    if ! systemctl is-enabled --quiet "wg-quick@$VPN_INTERFACE" 2>/dev/null \
        && ! systemctl enable --quiet "wg-quick@$VPN_INTERFACE" >>"$APP_LOG" 2>&1; then
        warn 'The VPN runs, but could not be enabled at boot (details in %s): after a restart of the server, it will not start by itself.' "$APP_LOG"
    fi
}

# Number of the client of a file of clients/: address 10.8.0.(N+1), port 60000+N
vpn_client_number() {
    (
        CLIENT_NUMBER=""
        # shellcheck source=/dev/null
        . "$1"
        printf '%s' "$CLIENT_NUMBER"
    )
}

vpn_next_client_number() {
    local number file used=" "
    for file in "$VPN_CLIENTS_DIR"/*.env; do
        [[ -e $file ]] || continue
        used+="$(
            # shellcheck source=/dev/null
            . "$file"
            printf '%s' "$CLIENT_NUMBER"
        ) "
    done
    for ((number = 1; number <= VPN_MAX_CLIENTS; number++)); do
        if [[ $used != *" $number "* ]]; then
            printf '%s' "$number"
            return 0
        fi
    done
    return 1
}

# --- Clients --------------------------------------------------------------------------

vpn_add_client() {
    local name=$1 CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY CLIENT_PRIVATE_KEY
    vpn_is_valid_client_name "$name" || die 'Invalid client name: "%s" (letters, digits, - and _, 15 characters at most).' "$name"
    [[ ! -e $VPN_CLIENTS_DIR/$name.env ]] || die 'Client "%s" already exists.' "$name"
    if ! CLIENT_NUMBER=$(vpn_next_client_number); then die 'Maximum number of clients reached (%s).' "$VPN_MAX_CLIENTS"; fi
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(printf '%s' "$CLIENT_PRIVATE_KEY" | wg pubkey)
    CLIENT_PRESHARED_KEY=$(wg genpsk)
    (umask 077 && state_write "$VPN_CLIENTS_DIR/$name.env" CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY CLIENT_PRIVATE_KEY)
    vpn_apply
    if ((INTERACTIVE)); then
        echo
        vpn_client_card "$name" ok "$(t 'Client "%s" created' "$name")"
        return 0
    fi
    ok 'Client "%s" created: IP %s, open port %s, file %s' "$name" "$VPN_SUBNET.$((CLIENT_NUMBER + 1))" \
        "$((VPN_FORWARDED_PORT_BASE + CLIENT_NUMBER))" "$VPN_CLIENTS_DIR/$name.conf"
}

# vpn_client_card NAME LEVEL TITLE — the card of a client, in a frame: its
# address in the VPN, its open port, its DNS and its file
vpn_client_card() {
    local name=$1 CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY CLIENT_PRIVATE_KEY
    # shellcheck source=/dev/null
    . "$VPN_CLIENTS_DIR/$name.env"
    ui_width
    ui_field_add "$(t 'Address in the VPN')" "$VPN_SUBNET.$((CLIENT_NUMBER + 1))"
    ui_field_add "$(t 'Open port')" "$(t '%s (TCP and UDP)' "$((VPN_FORWARDED_PORT_BASE + CLIENT_NUMBER))")"
    ui_field_add DNS "$(vpn_dns_label "$VPN_DNS")"
    ui_field_add "$(t 'File')" "$C_CYAN$VPN_CLIENTS_DIR/$name.conf$C_RESET"
    ui_box_fields "$2" "$3"
}

vpn_remove_client() {
    local name=$1
    vpn_require_client "$name"
    rm -f "$VPN_CLIENTS_DIR/$name.env" "$VPN_CLIENTS_DIR/$name.conf"
    vpn_apply
    ok 'Client "%s" revoked: its key can no longer connect.' "$name"
}

# vpn_qr_text FILE — the file of a client as put into its QR code: without its
# comments and empty lines, nor the spaces around « = » and after « , » (the
# WireGuard apps read both forms). The QR code is then about 65 columns wide
# instead of 89, and fits in a window of 80 columns. The file keeps them.
vpn_qr_text() {
    sed -E -e '/^[[:space:]]*(#|$)/d' -e 's/^([A-Za-z]+) = /\1=/' -e 's/, /,/g' -- "$1"
}

# vpn_print_qr FILE NAME [menu] — the QR code of the file of client NAME. In a
# window too small to show it whole, its lines would wrap and no phone could
# read it: what to do is said instead. Not in a terminal (a file, a pipe):
# printed. « menu »: alone on its screen, with one more line under it (the
# key to go on). VPN_QR_SHOWN: 1 if it was printed.
vpn_print_qr() {
    local file=$1 name=$2 menu=${3-} qr width height rows="" columns=""
    local -a lines
    VPN_QR_SHOWN=0
    qr=$(vpn_qr_text "$file" | qrencode -t ansiutf8 -m "$VPN_QR_MARGIN")
    mapfile -t lines <<<"$qr"
    height=${#lines[@]}
    if [[ -n $menu ]]; then height=$((height + 1)); fi
    ui_len "${lines[0]}"
    width=$UI_LEN
    if stdout_is_terminal; then read -r rows columns < <(ui_terminal_size) || true; fi
    if [[ $rows =~ ^[1-9][0-9]*$ && $columns =~ ^[1-9][0-9]*$ ]] && ((columns < width || rows < height)); then
        if [[ -n $menu ]]; then
            warn 'Window too small for the QR code: it needs %s columns and %s lines, this one has %s and %s. Make it bigger (or the font smaller), then R to show it again.' \
                "$width" "$height" "$columns" "$rows"
            if seedbox_installed; then say 'Or Enter, then 2: a one-time download link, to open on the device.'; fi
            return 0
        fi
        warn 'Window too small for the QR code: it needs %s columns and %s lines, this one has %s and %s. Make it bigger (or the font smaller), then:  seedtunnel vpn show %s' \
            "$width" "$height" "$columns" "$rows" "$name"
        if seedbox_installed; then say 'Or a one-time download link, to open on the device:  seedtunnel vpn share %s' "$name"; fi
        return 0
    fi
    printf '%s\n' "$qr"
    VPN_QR_SHOWN=1
}

# vpn_show_client NAME [created] — for the commands: the QR code, what to do
# with it, and the file. In the menus, three screens: the card of the client
# (not after « Add a client », which has just shown it), its QR code alone on
# the screen (so that it fits without scrolling), then what to do with it,
# with the file and the one-time link at hand.
vpn_show_client() {
    local name=$1 CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY CLIENT_PRIVATE_KEY port
    vpn_require_client "$name"
    # shellcheck source=/dev/null
    . "$VPN_CLIENTS_DIR/$name.env"
    port=$((VPN_FORWARDED_PORT_BASE + CLIENT_NUMBER))
    if ((!INTERACTIVE)); then
        section 'Client "%s"' "$name"
        vpn_print_qr "$VPN_CLIENTS_DIR/$name.conf" "$name"
        echo
        text vpn_client_help
        echo
        cat "$VPN_CLIENTS_DIR/$name.conf"
        return 0
    fi
    if [[ ${2-} != created ]]; then
        echo
        vpn_client_card "$name" good "$(t 'Client "%s"' "$name")"
        pause_next
    fi
    vpn_qr_screen "$name"
    vpn_client_screen "$name" "$port"
}

# The QR code alone on the screen. Too big for the window: R shows it again
# once the window is bigger, Enter goes on without it.
vpn_qr_screen() {
    local name=$1 choice
    while true; do
        ui_screen
        vpn_print_qr "$VPN_CLIENTS_DIR/$name.conf" "$name" menu
        if ((VPN_QR_SHOWN)); then
            if ! ui_pause next tight; then ui_quit; fi
            return 0
        fi
        echo
        ui_ask_choice choice r "$(t 'Show it again')" q "$(t 'Quit')"
        case ${choice,,} in
            r) ;;
            q) ui_quit ;;
            *) return 0 ;;
        esac
    done
}

# vpn_client_screen NAME PORT — what to do with the file of a client, and the
# keys to show it or to send it by a one-time link (with the seedbox)
vpn_client_screen() {
    local name=$1 port=$2 choice
    while true; do
        banner
        section 'Client "%s"' "$name"
        if seedbox_installed; then vpn_client_guide "$port" 1; else vpn_client_guide "$port" 0; fi
        echo
        ui_menu_add 1 "$(t 'Show the file (to copy and paste)')"
        if seedbox_installed; then ui_menu_add 2 "$(t 'One-time download link for the file')"; fi
        ui_menu_show
        echo
        ui_ask_choice choice b "$(t 'Back')" q "$(t 'Quit')"
        case ${choice,,} in
            1) ui_action vpn_client_file "$name" ;;
            2) if seedbox_installed; then ui_action vpn_client_link "$name"; fi ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# vpn_client_guide PORT LINK — in the menus, what to do with the file of a
# client, in three parts (to install the tunnel, the port for torrents, the
# kill switch). LINK: 1 when the key [2] (one-time link) is there.
vpn_client_guide() {
    local port=$1 link=$2 width=0 label
    for label in "$(t 'Phone')" "$(t 'Computer')" "$(t 'Open port')" "$(t 'Incoming')" Windows Android qBittorrent; do
        ui_len "$label"
        if ((UI_LEN > width)); then width=$UI_LEN; fi
    done
    ui_field_add "$(t 'Phone')" "$(t 'WireGuard → « + » → « Scan from QR code »')"
    if ((link)); then
        ui_field_add "$(t 'Computer')" "$(t 'WireGuard → « Import tunnel(s) from file »: the file through [2] or [1]')"
    else
        ui_field_add "$(t 'Computer')" "$(t 'WireGuard → « Import tunnel(s) from file »: the file through [1]')"
    fi
    ui_group "$(t 'Install the tunnel')" "$width"
    echo
    ui_field_add "$(t 'Open port')" "$(t '%s (TCP and UDP)' "$C_CYAN$port$C_RESET")"
    ui_field_add "$(t 'Incoming')" "$(t '%s → this client, while it is connected: set this port in your torrent program' "$C_CYAN$VPN_PUBLIC_ADDRESS:$port$C_RESET")"
    ui_group "$(t 'Port for torrents')" "$width"
    echo
    ui_field_add Windows "$(t 'WireGuard → Edit the tunnel → tick « Block untunneled traffic (kill-switch) »')"
    ui_field_add Android "$(t 'Settings → VPN → WireGuard (gear) → « Always-on VPN » and « Block connections without VPN »')"
    ui_field_add qBittorrent "$(t 'Options → Advanced → Network interface → the WireGuard tunnel')"
    ui_group "$(t 'Kill switch: if the tunnel drops, nothing goes out without it')" "$width"
}

vpn_client_file() {
    banner
    section 'File of the client "%s"' "$1"
    cat "$VPN_CLIENTS_DIR/$1.conf"
    pause
}

vpn_client_link() {
    banner
    section 'Download link for a client (one time only)'
    vpn_share_client "$1"
    pause
}

# One-time download link for the file of a client (see share.sh)
vpn_share_client() {
    local name=$1
    vpn_require_client "$name"
    share_require "$(t 'Without a seedbox:  seedtunnel vpn show %s  (QR code, or content to copy and paste).' "$name")"
    share_create "$VPN_CLIENTS_DIR/$name.conf" "$name.conf" "$(t 'VPN configuration "%s"' "$name")" \
        "$(text share_steps_vpn)" "$(t 'This file holds the secret key of "%s": delete it once imported.' "$name")"
}

# vpn_pick_client VARIABLE "Question (already translated)" — numbered list, pick
# by number or by name
vpn_pick_client() {
    local _pick_var=$1 _pick_question=$2 _pick_answer _pick_index=0 _pick_name
    local -a _pick_names
    mapfile -t _pick_names < <(vpn_client_names)
    if ((${#_pick_names[@]} == 0)); then
        warn 'No client yet.'
        return 1
    fi
    for _pick_name in "${_pick_names[@]}"; do
        _pick_index=$((_pick_index + 1))
        printf '  %2d) %s\n' "$_pick_index" "$_pick_name"
    done
    echo
    while true; do
        ask_back _pick_answer "$(t '%s (number or name)' "$_pick_question")" "" || return 1
        if [[ $_pick_answer =~ ^[0-9]{1,9}$ ]] && ((10#$_pick_answer >= 1 && 10#$_pick_answer <= ${#_pick_names[@]})); then
            _pick_answer=${_pick_names[10#$_pick_answer - 1]}
        fi
        if [[ $_pick_answer =~ ^[A-Za-z0-9_-]{1,15}$ && -e $VPN_CLIENTS_DIR/$_pick_answer.env ]]; then break; fi
        warn 'Client "%s" not found.' "$_pick_answer"
    done
    printf -v "$_pick_var" '%s' "$_pick_answer"
}

vpn_ask_client_name() {
    local _client_var=$1 _client_default=${2-} _client_name
    while true; do
        ask_back _client_name 'Client name (e.g. phone, laptop)' "$_client_default" || return 1
        if ! vpn_is_valid_client_name "$_client_name"; then
            warn 'Letters, digits, - and _ only, 15 characters at most.'
        elif [[ -e $VPN_CLIENTS_DIR/$_client_name.env ]]; then
            warn 'Client "%s" already exists.' "$_client_name"
        else
            break
        fi
    done
    printf -v "$_client_var" '%s' "$_client_name"
}

# vpn_last_connection SECONDS — the last connection of a client, from the age
# of its last handshake (0: none). WireGuard renews it every 2 minutes while
# the tunnel is open, and forgets it when the VPN restarts.
#   ● connected (12 s)                 green: the tunnel is open
#   ● 7 min ago                        yellow: open less than an hour ago
#   ○ 3 h ago / ○ 2 days ago           grey
#   ○ not since the VPN started        grey: since the last start (reboot…)
vpn_last_connection() {
    local ago=$1
    if ((ago < 0)); then
        printf '%s○ %s%s' "$C_GREY" "$(t 'not since the VPN started')" "$C_RESET"
    elif ((ago < 180)); then
        printf '%s● %s%s %s' "$C_GREEN" "$(t 'connected')" "$C_RESET" "$(t '(%s s)' "$ago")"
    elif ((ago < 3600)); then
        printf '%s● %s%s' "$C_YELLOW" "$(t '%s min ago' "$((ago / 60))")" "$C_RESET"
    elif ((ago < 86400)); then
        printf '%s○ %s%s' "$C_GREY" "$(t '%s h ago' "$((ago / 3600))")" "$C_RESET"
    else
        printf '%s○ %s%s' "$C_GREY" "$(t '%s days ago' "$((ago / 86400))")" "$C_RESET"
    fi
}

# Table of the clients with the state of their connection
vpn_status_table() {
    local -A handshakes=() received=() sent=()
    local key _psk _endpoint _ips handshake rx tx _keepalive file name now ago started
    local CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY CLIENT_PRIVATE_KEY
    if systemctl is-active --quiet "wg-quick@$VPN_INTERFACE"; then
        while IFS=$'\t' read -r key _psk _endpoint _ips handshake rx tx _keepalive; do
            handshakes[$key]=$handshake
            received[$key]=$rx
            sent[$key]=$tx
        done < <(wg show "$VPN_INTERFACE" dump | tail -n +2)
        # the connections are counted from there
        started=$(systemctl show -P ActiveEnterTimestamp "wg-quick@$VPN_INTERFACE" 2>/dev/null || true)
        # (« date -d "" » would give midnight: nothing said without a date)
        if [[ -n $started ]] && started=$(date -d "$started" '+%F %R' 2>/dev/null); then
            printf '  %s\n\n' "$(t 'VPN running since %s.' "$started")"
        fi
    else
        warn 'The VPN is stopped: no client can connect.'
        echo
    fi
    local -a rows=()
    now=$(date +%s)
    rows+=("$(t 'CLIENT')"$'\t'IP$'\t'PORT$'\t'"$(t 'RECEIVED / SENT')"$'\t'"$(t 'LAST CONNECTION')")
    for file in "$VPN_CLIENTS_DIR"/*.env; do
        [[ -e $file ]] || continue
        name=${file##*/}
        name=${name%.env}
        # shellcheck source=/dev/null
        . "$file"
        handshake=${handshakes[$CLIENT_PUBLIC_KEY]:-0}
        if ((handshake == 0)); then
            ago=-1
        elif ((handshake > now)); then
            ago=0
        else
            ago=$((now - handshake))
        fi
        rows+=("$name"$'\t'"$VPN_SUBNET.$((CLIENT_NUMBER + 1))"$'\t'"$((VPN_FORWARDED_PORT_BASE + CLIENT_NUMBER))"$'\t'"$(human_size "${received[$CLIENT_PUBLIC_KEY]:-0}") / $(human_size "${sent[$CLIENT_PUBLIC_KEY]:-0}")"$'\t'"$(vpn_last_connection "$ago")")
    done
    ui_width
    ui_table "${rows[@]}"
}

# --- Settings, installation, removal ---------------------------------------------

# vpn_dns_choices CURRENT — the DNS services to choose from, like the entries
# of a menu, a ● next to the one in use (CURRENT: its number). Without room
# for its note on the same line, the note goes under it.
vpn_dns_choices() {
    local current=$1 i line mark part
    local -a names=(Quad9 Cloudflare DNS4EU AdGuard "$(t 'Other')")
    local -a notes=()
    notes+=("$(t 'blocks malicious domains (Swiss foundation)')" "$(t 'usually the fastest')")
    notes+=("$(t 'European Union, blocks malicious domains')" "$(t 'also blocks ads and trackers')" "$(t 'type the addresses')")
    ui_width
    for i in "${!names[@]}"; do
        ui_key $((i + 1))
        mark=""
        if ((i + 1 == current)); then mark=" $C_GREEN●$C_RESET"; fi
        ui_pad "${names[i]}$mark" 13
        line="  $UI_KEY $UI_PAD $C_GREY${notes[i]}$C_RESET"
        ui_len "$line"
        if ((UI_LEN <= UI_WIDTH)); then
            printf '%s\n' "$line"
            continue
        fi
        ui_print "  $UI_KEY ${names[i]}$mark"
        ui_wrap "${notes[i]}" $((UI_WIDTH - 6))
        for part in "${UI_LINES[@]}"; do ui_print "      $C_GREY$part$C_RESET"; done
    done
}

# Sets VPN_DNS. The choice suggested is the one in use (Quad9 at the
# installation). Status 1: back, VPN_DNS left alone.
vpn_ask_dns() {
    local choice current=5 index=0 key addresses
    for key in "${VPN_DNS_SERVICES[@]}"; do
        index=$((index + 1))
        if [[ $(vpn_dns_service "$VPN_DNS") == "$key" ]]; then current=$index; fi
    done
    echo
    say 'DNS servers used by the VPN clients:'
    vpn_dns_choices "$current"
    echo
    while true; do
        ask_back choice 'Your choice [1-5]' "$current" || return 1
        case $choice in
            [1-4])
                VPN_DNS=$(vpn_dns_value "${VPN_DNS_SERVICES[choice - 1]}")
                return 0
                ;;
            5)
                addresses=$VPN_DNS
                ask_back addresses 'DNS IP address(es), separated by commas' "$addresses" || return 1
                if vpn_is_valid_dns "$addresses"; then
                    VPN_DNS=$(vpn_dns_normalize "$addresses")
                    return 0
                fi
                warn 'Expected format: 9.9.9.9, 149.112.112.112'
                ;;
        esac
    done
}

# vpn_ask_settings install|change — questions of the installation, or of the
# change of the address or the port (the DNS has its own screen then). Status
# 1: the user went back (empty answer, or « no » at the end), nothing to change.
vpn_ask_settings() {
    local mode=$1 port_in_use=$VPN_PORT address_in_use=$VPN_PUBLIC_ADDRESS address port
    while true; do
        ask_back VPN_PUBLIC_ADDRESS 'Public address of the server (IP or domain name)' "$VPN_PUBLIC_ADDRESS" || return 1
        if vpn_is_valid_address "$VPN_PUBLIC_ADDRESS"; then break; fi
        warn 'Invalid address.'
    done
    while true; do
        ask_back VPN_PORT 'UDP port of the VPN' "$VPN_PORT" || return 1
        if ! is_valid_port "$VPN_PORT"; then
            warn 'Invalid port (1 to 65535).'
        elif ! vpn_port_is_free "$VPN_PORT"; then
            warn 'UDP port %s is already used on this server.' "$VPN_PORT"
        else
            break
        fi
    done
    if [[ $mode == install ]]; then vpn_ask_dns || return 1; fi
    # what changes: « before → after »
    address=$VPN_PUBLIC_ADDRESS
    port="$VPN_PORT/udp"
    if [[ $mode == change ]]; then
        if [[ $VPN_PUBLIC_ADDRESS != "$address_in_use" ]]; then address="$address_in_use → $C_BOLD$VPN_PUBLIC_ADDRESS$C_RESET"; fi
        if [[ $VPN_PORT != "$port_in_use" ]]; then port="$port_in_use → $C_BOLD$VPN_PORT/udp$C_RESET"; fi
    fi
    echo
    ui_width
    ui_field_add "$(t 'Address')" "$address"
    ui_field_add Port "$port"
    ui_field_add DNS "$(vpn_dns_label "$VPN_DNS")"
    ui_field_add "$(t 'Way out')" "$(t 'interface %s' "${VPN_OUT_INTERFACE:-?}")"
    ui_box_fields good "$(t 'Summary')"
    echo
    # a new port restarts the VPN: every tunnel is cut, this session too if it
    # goes through the VPN (« no » by default then)
    if [[ $mode == change && $VPN_PORT != "$port_in_use" ]]; then
        warn 'New port: the VPN restarts and every client is disconnected until it imports its new configuration.'
        if [[ $(ssh_session_source) == "$VPN_SUBNET".* ]]; then
            warn 'This SSH session goes through the VPN: it will be cut too. Reconnect without the VPN to import the new configuration.'
            confirm 'Change the port anyway?' n || return 1
            return 0
        fi
        echo
    fi
    confirm 'Is that right?' y
}

vpn_install_interactive() {
    local first
    banner
    section 'WireGuard VPN installation'
    ufw_refuse
    vpn_check_kernel
    base_setup
    echo
    printf '%s ' "$(t 'Looking for the public IP address…')"
    VPN_PUBLIC_ADDRESS=$(public_ipv4)
    echo "${VPN_PUBLIC_ADDRESS:-$(t 'not found')}"
    # if the seedbox has a domain name, it makes a better address
    if seedbox_installed && [[ -n $SEEDBOX_DOMAIN ]] && ! is_ipv4 "$SEEDBOX_DOMAIN"; then
        VPN_PUBLIC_ADDRESS=$SEEDBOX_DOMAIN
    fi
    VPN_OUT_INTERFACE=$(default_interface)
    echo
    # going back: the VPN is not installed
    vpn_ask_settings install || return 0
    echo
    vpn_ask_client_name first "client1" || return 0
    echo
    vpn_apply
    vpn_add_client "$first"
    echo
    ok 'VPN installed — no restart needed.'
    pause_next
    vpn_show_client "$first" created
}

# Installation (or putting back in order) from a --config file. Run again with
# the same file, it changes nothing: existing clients are kept.
vpn_install_from_config() {
    local name port dns
    local -a names=()
    ufw_refuse
    vpn_check_kernel
    base_setup
    VPN_PUBLIC_ADDRESS=$(config_get VPN_PUBLIC_ADDRESS "$VPN_PUBLIC_ADDRESS")
    if [[ -z $VPN_PUBLIC_ADDRESS ]]; then VPN_PUBLIC_ADDRESS=$(public_ipv4); fi
    vpn_is_valid_address "$VPN_PUBLIC_ADDRESS" || die 'Invalid VPN_PUBLIC_ADDRESS: "%s"' "$VPN_PUBLIC_ADDRESS"
    port=$(config_get VPN_PORT "$VPN_PORT")
    is_valid_port "$port" || die 'Invalid VPN_PORT: "%s"' "$port"
    vpn_port_is_free "$port" || die 'UDP port %s is already used on this server.' "$port"
    VPN_PORT=$port
    # quad9, cloudflare, dns4eu, adguard, or addresses
    dns=$(vpn_dns_value "$(config_get VPN_DNS "$VPN_DNS")")
    vpn_is_valid_dns "$dns" || die 'Invalid VPN_DNS: "%s"' "$dns"
    VPN_DNS=$(vpn_dns_normalize "$dns")
    IFS=', ' read -r -a names <<<"$(config_get VPN_CLIENTS)"
    for name in "${names[@]}"; do
        vpn_is_valid_client_name "$name" || die 'VPN_CLIENTS: invalid name "%s"' "$name"
    done

    vpn_apply
    for name in "${names[@]}"; do
        if [[ ! -e $VPN_CLIENTS_DIR/$name.env ]]; then vpn_add_client "$name"; fi
    done
    ok 'VPN ready: %s, %s client(s) in %s' "$VPN_PUBLIC_ADDRESS:$VPN_PORT/udp" "$(vpn_count_clients)" "$VPN_CLIENTS_DIR/"
}

vpn_change_settings() {
    WENT_BACK=0
    banner
    section 'Change the address or the port'
    warn 'After a change, every client will have to import its configuration again.'
    echo
    if ! vpn_ask_settings change; then
        WENT_BACK=1
        return 0
    fi
    vpn_apply
    ok 'Settings saved. Show the clients again to get their new QR codes.'
}

# vpn_set_dns ADDRESSES — new DNS for the clients. It is written in the file of
# each client: a client keeps the previous one until it imports its new file.
vpn_set_dns() {
    local old=$VPN_DNS
    VPN_DNS=$(vpn_dns_normalize "$1")
    if [[ $(tr -d '[:space:]' <<<"$VPN_DNS") == "$(tr -d '[:space:]' <<<"$old")" ]]; then
        ok 'Nothing to change: the clients already use %s.' "$(vpn_dns_label "$old")"
        return 0
    fi
    log_title 'Changing the DNS of the clients: %s' "$(vpn_dns_label "$VPN_DNS")"
    vpn_apply
    ok 'DNS of the clients: %s.' "$(vpn_dns_label "$VPN_DNS")"
    if (($(vpn_count_clients) > 0)); then
        warn 'Each client keeps the old DNS until it imports its configuration again.'
    fi
}

vpn_change_dns() {
    local old=$VPN_DNS new
    WENT_BACK=0
    banner
    section 'Change the DNS of the clients'
    ui_width
    ui_field_add "$(t 'In use')" "$(vpn_dns_label "$VPN_DNS")"
    ui_fields_show
    if ! vpn_ask_dns; then
        WENT_BACK=1
        return 0
    fi
    new=$VPN_DNS
    VPN_DNS=$old
    echo
    vpn_set_dns "$new"
}

vpn_uninstall() {
    local -a lines
    local note
    banner
    section 'Remove the VPN'
    lines=("$(t 'All the clients (%s) will be deleted for good.' "$(vpn_count_clients)")" "$(t 'Their files and QR codes will no longer work.')")
    # the last part removed: the weekly backup and its passphrase go too
    note=$(backup_removal_note seedbox)
    if [[ -n $note ]]; then lines+=("$note"); fi
    danger "$(t 'Remove the VPN')" "${lines[@]}"
    if ! confirm 'Remove the VPN?' n; then return 0; fi
    echo
    log_run 'Stopping the VPN' systemctl disable --now "wg-quick@$VPN_INTERFACE"
    nft_delete_table ip seedtunnel
    # A running interface keeps the clients it knows, files or not: the keys are
    # only deleted once the VPN is really stopped
    if ip link show "$VPN_INTERFACE" &>/dev/null || nft list table ip seedtunnel &>/dev/null; then
        die 'The VPN could not be stopped (details in %s): nothing was deleted. Try again, or:  systemctl stop wg-quick@%s' "$APP_LOG" "$VPN_INTERFACE"
    fi
    rm -rf "${VPN_STATE_DIR:?}" "$VPN_CONF_FILE" "$WIREGUARD_CONF" "$VPN_SYSCTL_FILE" "$VPN_SYSTEMD_DROPIN"
    # the folder only if nothing else is in it (an addition of the administrator)
    rmdir "${VPN_SYSTEMD_DROPIN%/*}" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    net_hardening_cleanup
    apt_purge wireguard-tools qrencode
    firewall_refresh
    backup_auto_stop_if_unused
    ok 'VPN removed (IPv4 routing will be turned off at the next restart).'
    pause
}

# --- Menu --------------------------------------------------------------------------
# Each action runs in a subshell (ui_action): an error comes back to the menu.

vpn_menu_add() {
    local name
    banner
    section 'Add a client'
    if (($(vpn_count_clients) >= VPN_MAX_CLIENTS)); then
        warn 'Maximum number of clients reached (%s).' "$VPN_MAX_CLIENTS"
        pause
    elif vpn_ask_client_name name ""; then
        vpn_add_client "$name"
        pause_next
        vpn_show_client "$name" created
    fi
}

vpn_menu_show() {
    local name
    banner
    section 'Show a client (QR code, file)'
    if vpn_pick_client name "$(t 'Client to show')"; then vpn_show_client "$name"; fi
}

vpn_menu_link() {
    local name
    banner
    section 'Download link for a client (one time only)'
    if ! seedbox_installed; then
        warn 'Links go through the HTTPS site of the seedbox, which is not installed:'
        warn 'use "Show a client" instead (QR code, or content to copy and paste).'
        pause
    elif vpn_pick_client name "$(t 'Client to send')"; then
        vpn_share_client "$name"
        pause
    fi
}

vpn_menu_revoke() {
    local name
    banner
    section 'Revoke a client'
    vpn_pick_client name "$(t 'Client to revoke')" || return 0
    echo
    danger "$(t 'Revoke "%s"' "$name")" "$(t 'This device will no longer be able to connect to the VPN.')" \
        "$(t 'Its file and its QR code stop working: this cannot be undone.')"
    if confirm "$(t 'Revoke "%s" for good?' "$name")" n; then
        vpn_remove_client "$name"
        pause
    fi
}

vpn_menu_clients() {
    banner
    section 'Clients and connections'
    vpn_status_table
    pause
}

vpn_menu_settings() {
    vpn_change_settings
    if ((!WENT_BACK)); then pause; fi
}

vpn_menu_dns() {
    vpn_change_dns
    if ((!WENT_BACK)); then pause; fi
}

vpn_menu_restart() {
    echo
    run 'Restarting the VPN' systemctl restart "wg-quick@$VPN_INTERFACE"
    pause
}

vpn_menu() {
    local choice
    while true; do
        vpn_load
        vpn_installed || return 0
        UI_PLACE=(VPN)
        ui_top VPN
        ui_field_add "$(t 'State')" "$(service_state "wg-quick@$VPN_INTERFACE")"
        ui_field_add "$(t 'Address')" "$C_CYAN$VPN_PUBLIC_ADDRESS:$VPN_PORT$C_RESET (UDP)"
        ui_field_add Clients "$(t '%s (%s connected right now)' "$(vpn_count_clients)" "$(vpn_connected_count)")"
        ui_field_add DNS "$(vpn_dns_label "$VPN_DNS")"
        ui_fields_show
        echo
        ui_menu_add 1 "$(t 'Add a client')"
        ui_menu_add 2 "$(t 'Show a client (QR code, file)')"
        ui_menu_add 3 "$(t 'Download link for a client (one time only)')"
        ui_menu_add 4 "$(t 'Revoke a client')"
        ui_menu_add 5 "$(t 'Clients and connections')"
        ui_menu_gap
        ui_menu_add 6 "$(t 'Change the address or the port')"
        ui_menu_add 7 "$(t 'Change the DNS of the clients')"
        ui_menu_add 8 "$(t 'Restart the VPN')"
        ui_menu_add 9 "$(t 'Remove the VPN')"
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action vpn_menu_add ;;
            2) ui_action vpn_menu_show ;;
            3) ui_action vpn_menu_link ;;
            4) ui_action vpn_menu_revoke ;;
            5) ui_action vpn_menu_clients ;;
            6) ui_action vpn_menu_settings ;;
            7) ui_action vpn_menu_dns ;;
            8) ui_action vpn_menu_restart ;;
            9) ui_action vpn_uninstall ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

vpn_main() {
    vpn_load
    if vpn_installed && (($(vpn_count_clients) == 0)) && ! systemctl is-active --quiet "wg-quick@$VPN_INTERFACE"; then
        # settings saved but neither client nor service: interrupted installation
        warn 'The previous installation of the VPN was interrupted: starting it again.'
        pause
        vpn_install_interactive
    elif vpn_installed; then
        vpn_menu
    else
        vpn_install_interactive
    fi
}

# seedtunnel vpn <command> …
vpn_cli() {
    local command=${1-} dns
    if (($#)); then shift; fi
    case $command in
        "")
            require_terminal
            vpn_main
            ;;
        install)
            if [[ -n $OPT_CONFIG_FILE ]]; then
                config_load "$OPT_CONFIG_FILE"
                vpn_install_from_config
                if [[ $(config_get FIREWALL) == yes ]]; then firewall_enable; fi
            else
                require_terminal
                if vpn_installed; then die 'The VPN is already installed (seedtunnel vpn to manage it).'; fi
                vpn_install_interactive
            fi
            ;;
        add)
            vpn_require_installed
            [[ -n ${1-} ]] || die 'Usage: seedtunnel vpn add NAME [--qr]'
            vpn_add_client "$1"
            if ((OPT_QR)); then vpn_show_client "$1"; fi
            ;;
        remove)
            vpn_require_installed
            [[ -n ${1-} ]] || die 'Usage: seedtunnel vpn remove NAME --yes'
            vpn_require_client "$1"
            if confirm "$(t 'Revoke "%s" for good?' "$1")" n; then vpn_remove_client "$1"; fi
            ;;
        list)
            vpn_require_installed
            vpn_status_table
            ;;
        show)
            vpn_require_installed
            [[ -n ${1-} ]] || die 'Usage: seedtunnel vpn show NAME'
            vpn_show_client "$1"
            ;;
        share)
            vpn_require_installed
            [[ -n ${1-} ]] || die 'Usage: seedtunnel vpn share NAME'
            vpn_share_client "$1"
            ;;
        dns)
            vpn_require_installed
            if (($# == 0)); then
                say 'DNS of the clients: %s.' "$(vpn_dns_label "$VPN_DNS")"
            else
                # « 9.9.9.9, 1.1.1.1 » arrives in two words
                dns=$(vpn_dns_value "$*")
                vpn_is_valid_dns "$dns" || die 'Usage: seedtunnel vpn dns [quad9|cloudflare|dns4eu|adguard|IP,IP…]'
                vpn_set_dns "$dns"
            fi
            ;;
        restart)
            vpn_require_installed
            run 'Restarting the VPN' systemctl restart "wg-quick@$VPN_INTERFACE"
            ;;
        uninstall)
            vpn_require_installed
            vpn_uninstall
            ;;
        *) die 'Unknown command: vpn %s   (help: seedtunnel help)' "$command" ;;
    esac
}
