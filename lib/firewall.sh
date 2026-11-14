#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — firewall (nftables)
#
#  Everything that reaches the server is refused, except:
#    - replies to connections already open, ICMP (ping, IPv6);
#    - SSH on the port(s) really used by sshd and by the current session;
#    - the VPN and the seedbox if they are installed.
#  The rules live in their own table (inet seedtunnel_fw): fail2ban, Docker or
#  other tools keep theirs.
#
#  Safety when enabling: the new rules are tried from their own file, with an
#  automatic undo 2 minutes later; they are only kept if confirmed from a NEW
#  SSH connection. Undoing puts back the rules in use before (or no rules if
#  the firewall was off): the rules loaded at boot only change once confirmed.
# =============================================================================

FIREWALL_CONF_FILE="$APP_STATE_DIR/firewall.conf"
FIREWALL_RULES="$APP_STATE_DIR/firewall.nft"
FIREWALL_CANDIDATE="$APP_STATE_DIR/firewall.nft.new"
FIREWALL_UNIT="/etc/systemd/system/seedtunnel-firewall.service"
FIREWALL_TABLE="seedtunnel_fw"
FIREWALL_ROLLBACK_UNIT="seedtunnel-firewall-rollback"

firewall_load() {
    FIREWALL_ENABLED=0
    state_read "$FIREWALL_CONF_FILE"
}

firewall_enabled() {
    firewall_load
    ((FIREWALL_ENABLED == 1))
}

# Ports of ssh.socket, when systemd starts SSH on demand (Ubuntu): those are
# the ports really open, even if the configuration of sshd says another one
ssh_socket_ports() {
    systemctl is-active --quiet ssh.socket 2>/dev/null || return 0
    systemctl show -p Listen --value ssh.socket 2>/dev/null | grep -oE '[0-9]+ \(Stream\)' | awk '{ print $1 }' || true
}

# SSH ports: those of sshd (its configuration, and where it listens) and of
# ssh.socket, plus the one of the current connection (just in case: sudo
# leaves SSH_CONNECTION out)
firewall_ssh_ports() {
    local settings ports
    settings=$(sshd_settings)
    ports=$(awk '$1 == "port" { print $2 }' <<<"$settings")
    ports+=$'\n'$(ssh_socket_ports)
    # where sshd really listens: started with other ports, or its configuration
    # changed but not read yet (ports of its configuration, read at its restart)
    ports+=$'\n'$(ss -Hltnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }' || true)
    if [[ -n ${SSH_CONNECTION-} ]]; then ports+=$'\n'"${SSH_CONNECTION##* }"; fi
    ports=$(awk '/^[0-9]+$/ && !seen[$0]++' <<<"$ports" | paste -sd, -)
    ports=${ports:-22}
    printf '%s' "${ports//,/, }"
}

# Ports on which SSH really listens, plus those of its configuration (used at
# the next restart of SSH)
firewall_sshd_ports() {
    {
        sshd_settings | awk '$1 == "port" { print $2 }'
        ss -Hltnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
        ssh_socket_ports
    } | awk '/^[0-9]+$/ && !seen[$0]++' || true
}

# TCP ports accepted by loaded rules (text of « nft list » on standard input)
firewall_open_tcp_ports() {
    { grep -oE 'tcp dport (\{[^}]*\}|[0-9]+) accept' || true; } | { grep -oE '[0-9]+' || true; } | sort -un
}

# Do loaded rules (text of « nft list » on standard input) have their input
# chain, refusing by default what is not allowed?
firewall_refuses_by_default() { grep -qE 'type filter hook input priority [^;]*; policy drop;'; }

# --- The rules in words (« seedtunnel firewall rules ») -------------------------------
# What nftables really has loaded, not what the settings say: what differs
# from the settings is said. Nothing is changed.

# One allowed line of the list (text already translated)
firewall_rule_line() { printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }

# firewall_rule_found KIND LABEL VALUE TEXT — what firewall_rules_in_words
# found. For the commands, TEXT on its line (KIND other: a warning). With
# FW_COLLECT=1 (the screen of the menu): kept in FW_OPEN_* (open, a port),
# FW_ALWAYS_* (always, a rule of every server) or FW_OTHERS (other).
firewall_rule_found() {
    if ((${FW_COLLECT:-0})); then
        case $1 in
            open)
                FW_OPEN_LABELS+=("$2")
                FW_OPEN_VALUES+=("$3")
                ;;
            always)
                FW_ALWAYS_LABELS+=("$2")
                FW_ALWAYS_VALUES+=("$3")
                ;;
            *) FW_OTHERS+=("$4") ;;
        esac
    elif [[ $1 == other ]]; then
        printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$4"
    else
        firewall_rule_line "$4"
    fi
}

# Numbers in a rule: « tcp dport { 22, 2222 } accept » → 22 2222
firewall_rule_numbers() { grep -oE '[0-9]+' <<<"${1#*dport}" | paste -sd' ' -; }

# The allowed lines of loaded rules (« nft list » on standard input), in words
firewall_rules_in_words() {
    local line port ssh web other
    local -a ssh_ports
    read -r -a ssh_ports <<<"$(firewall_ssh_ports | tr -d ',')"
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        case $line in
            *" accept") ;;
            *) continue ;;
        esac
        case $line in
            "ct state established,related accept")
                firewall_rule_found always "$(t 'Replies')" "$(t 'to the connections already open')" "$(t 'Replies to the connections already open')"
                ;;
            'iifname "lo" accept')
                firewall_rule_found always "$(t 'Local')" "$(t 'the server itself')" "$(t 'The server talking to itself')"
                ;;
            "iifname \"$VPN_INTERFACE\" accept")
                firewall_rule_found always VPN "$(t 'everything coming from the VPN clients')" "$(t 'Everything coming from the VPN clients')"
                ;;
            "ip6 saddr fe80::/10 udp dport 546 accept")
                firewall_rule_found always "$(t 'Network')" "$(t 'IPv6 address from the provider (DHCPv6)')" "$(t 'IPv6 address given by the provider (DHCPv6)')"
                ;;
            "meta l4proto {"*"} accept")
                if [[ $line == *icmp* || $line == *"1, 58"* ]]; then
                    firewall_rule_found always "$(t 'Network')" "$(t 'ping and ICMP (IPv4 and IPv6)')" "$(t 'Ping and ICMP messages (IPv4 and IPv6)')"
                else
                    firewall_rule_found other "" "" "$(t 'Other rule: %s' "$line")"
                fi
                ;;
            "tcp dport "*" accept")
                ssh="" web="" other=""
                for port in $(firewall_rule_numbers "$line"); do
                    if [[ " ${ssh_ports[*]} " == *" $port "* ]]; then
                        ssh+="${ssh:+, }$port"
                    elif [[ $port == 80 || $port == 443 ]]; then
                        web+="${web:+, }$port"
                    else
                        other+="${other:+, }$port"
                    fi
                done
                if [[ -n $ssh ]]; then
                    firewall_rule_found open "SSH / SFTP" "$C_CYAN$ssh$C_RESET/tcp" "$(t 'SSH / SFTP: port %s/tcp' "$ssh")"
                fi
                if [[ -n $web ]]; then
                    firewall_rule_found open "$(t 'Web site')" "$C_CYAN$web$C_RESET/tcp" "$(t 'Web site: ports %s/tcp' "$web")"
                fi
                if [[ -n $other ]]; then firewall_rule_found other "" "" "$(t 'Other port open: %s/tcp' "$other")"; fi
                ;;
            "udp dport "*" accept")
                port=$(firewall_rule_numbers "$line")
                if vpn_installed && [[ $port == "$VPN_PORT" ]]; then
                    firewall_rule_found open "$(t 'VPN WireGuard')" "$C_CYAN$port$C_RESET/udp" "$(t 'VPN WireGuard: port %s/udp' "$port")"
                else
                    firewall_rule_found other "" "" "$(t 'Other port open: %s/udp' "$port")"
                fi
                ;;
            "meta l4proto { "*" } th dport "*" accept")
                port=$(firewall_rule_numbers "$line")
                if seedbox_installed && [[ $port == "$TORRENT_PORT" ]]; then
                    firewall_rule_found open BitTorrent "$(t '%s (TCP and UDP)' "$C_CYAN$port$C_RESET")" "$(t 'BitTorrent: port %s (TCP and UDP)' "$port")"
                else
                    firewall_rule_found other "" "" "$(t 'Other port open: %s (TCP and UDP)' "$port")"
                fi
                ;;
            *) firewall_rule_found other "" "" "$(t 'Other rule: %s' "$line")" ;;
        esac
    done
}

# Ports the settings want open but that the loaded rules ($1) do not have
firewall_rules_missing() {
    local missing
    missing=$(firewall_rules_missing_list "$1")
    if [[ -n $missing ]]; then
        err 'Missing from the rules loaded, although the settings need it: %s   → seedtunnel apply' "$missing"
    fi
}

# firewall_rules_missing_list RULES — what the settings need and the rules
# loaded do not open (« SSH 22/tcp, web 443/tcp »), nothing if all is there
firewall_rules_missing_list() {
    local rules=$1 port missing="" open
    open=" $(firewall_open_tcp_ports <<<"$rules" | paste -sd' ' -) "
    for port in $(firewall_ssh_ports | tr -d ','); do
        if [[ $open != *" $port "* ]]; then missing+="${missing:+, }SSH $port/tcp"; fi
    done
    if vpn_installed && ! grep -qE "udp dport $VPN_PORT accept" <<<"$rules"; then missing+="${missing:+, }VPN $VPN_PORT/udp"; fi
    if seedbox_installed || links_site_on; then
        for port in 80 443; do
            if [[ $open != *" $port "* ]]; then missing+="${missing:+, }web $port/tcp"; fi
        done
    fi
    if seedbox_installed && ! grep -qE "th dport $TORRENT_PORT accept" <<<"$rules"; then
        missing+="${missing:+, }BitTorrent $TORRENT_PORT"
    fi
    printf '%s' "$missing"
}

# Ports forwarded to the clients of the VPN (NAT of the VPN, loaded right now):
# FW_FORWARDED, rows « port<tab>client<tab>address ». Status 1: the VPN does
# not run (no NAT loaded).
firewall_forwarded_rows() {
    local nat line port address number name file
    FW_FORWARDED=()
    nat=$(nft list table ip seedtunnel 2>/dev/null || true)
    [[ -n $nat ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ th\ dport\ ([0-9]+)\ dnat\ (ip\ )?to\ ([0-9.]+) ]] || continue
        port=${BASH_REMATCH[1]}
        address=${BASH_REMATCH[3]}
        # client number N: address 10.8.0.(N+1), port 60000+N
        number=$((${address##*.} - 1))
        name="?"
        for file in "$VPN_CLIENTS_DIR"/*.env; do
            vpn_is_client_file "$file" || continue
            if [[ $(vpn_client_number "$file") == "$number" ]]; then
                name=${file##*/}
                name=${name%.env}
            fi
        done
        FW_FORWARDED+=("$port"$'\t'"$name"$'\t'"$address")
    done <<<"$nat"
}

# Ports forwarded to the clients of the VPN, for the commands
firewall_forwarded_ports() {
    local row port name address
    if ! firewall_forwarded_rows; then
        printf '  %s\n' "$(t 'none: the VPN is not running')"
        return 0
    fi
    if ((${#FW_FORWARDED[@]} == 0)); then
        printf '  %s\n' "$(t 'none: no client yet')"
        return 0
    fi
    for row in "${FW_FORWARDED[@]}"; do
        IFS=$'\t' read -r port name address <<<"$row"
        printf '  %s●%s %s\n' "$C_GREEN" "$C_RESET" "$(t 'port %s (TCP and UDP) → %s (%s)' "$port" "$name" "$address")"
    done
}

firewall_rules_show() {
    local rules
    if ! firewall_enabled; then
        warn 'Firewall off: nothing is refused, every port of the server can be reached.'
    else
        rules=$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true)
        if [[ -z $rules ]]; then
            err 'Firewall enabled but rules missing:  seedtunnel firewall enable --yes'
        else
            say 'Allowed towards the server (rules loaded right now):'
            firewall_rules_in_words <<<"$rules"
            if firewall_refuses_by_default <<<"$rules"; then
                printf '  %s\n' "$(t 'Everything else is refused.')"
            else
                err 'Everything else is accepted: these rules refuse nothing by default   → seedtunnel firewall enable --yes'
            fi
            firewall_rules_missing "$rules"
        fi
    fi
    if vpn_installed; then
        echo
        say 'Ports forwarded to the VPN clients (they can be reached from the Internet, the firewall does not filter them):'
        firewall_forwarded_ports
    fi
}

# In the menus: the rules loaded right now, laid out (a frame that sums them
# up, the open ports, what every server allows, the ports forwarded to the
# clients of the VPN), and the raw rules at hand ([1])
firewall_rules_menu() {
    local choice
    while true; do
        banner
        section 'Show the rules'
        firewall_rules_screen
        echo
        ui_menu_add 1 "$(t 'Show the raw rules (nftables)')"
        ui_menu_show
        echo
        ui_ask_choice choice b "$(t 'Back')" q "$(t 'Quit')"
        case ${choice,,} in
            1) ui_action firewall_raw_rules ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

firewall_raw_rules() {
    banner
    section 'Raw rules (nftables)'
    nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true
    nft list table ip seedtunnel 2>/dev/null || true
    pause
}

firewall_rules_screen() {
    local rules width=0 label i
    local -a FW_OPEN_LABELS=() FW_OPEN_VALUES=() FW_ALWAYS_LABELS=() FW_ALWAYS_VALUES=() FW_OTHERS=() FW_FORWARDED=()
    if ! firewall_enabled; then
        ui_box warn "$(t 'Firewall off')" "$(t 'Nothing is refused: every port of the server can be reached.')" \
            "$(t 'To turn it on: choice 1 of the Firewall menu.')"
        firewall_rules_forwarded_group 0
        return 0
    fi
    rules=$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true)
    if [[ -z $rules ]]; then
        ui_box bad "$(t 'Rules missing')" "$(t 'The firewall is on, but its rules are not loaded:')" "seedtunnel firewall enable --yes"
        firewall_rules_forwarded_group 0
        return 0
    fi
    if firewall_refuses_by_default <<<"$rules"; then
        ui_field_add "$(t 'By default')" "$(t 'everything coming in is refused')"
        ui_field_add "$(t 'Rules')" "$(t 'those loaded right now')"
        ui_box_fields good "$(t 'Firewall on')"
    else
        ui_box bad "$(t 'Everything is accepted')" "$(t 'These rules refuse nothing by default:')" "seedtunnel firewall enable --yes"
    fi
    firewall_rules_missing "$rules"
    FW_COLLECT=1 firewall_rules_in_words <<<"$rules"
    # the merged « Network » line: ping and ICMP, DHCPv6
    for i in "${!FW_ALWAYS_LABELS[@]}"; do
        if ((i > 0)) && [[ ${FW_ALWAYS_LABELS[i]} == "${FW_ALWAYS_LABELS[i - 1]}" ]]; then
            FW_ALWAYS_VALUES[i - 1]+=", ${FW_ALWAYS_VALUES[i]}"
            FW_ALWAYS_LABELS[i]=""
        fi
    done
    for label in "${FW_OPEN_LABELS[@]}" "${FW_ALWAYS_LABELS[@]}"; do
        ui_len "$label"
        if ((UI_LEN > width)); then width=$UI_LEN; fi
    done
    echo
    for i in "${!FW_OPEN_LABELS[@]}"; do ui_field_add "${FW_OPEN_LABELS[i]}" "${FW_OPEN_VALUES[i]}"; done
    ui_group "$(t 'Ports open on the server')" "$width"
    for label in "${FW_OTHERS[@]}"; do printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$label"; done
    echo
    for i in "${!FW_ALWAYS_LABELS[@]}"; do
        if [[ -n ${FW_ALWAYS_LABELS[i]} ]]; then ui_field_add "${FW_ALWAYS_LABELS[i]}" "${FW_ALWAYS_VALUES[i]}"; fi
    done
    ui_group "$(t 'Always allowed')" "$width"
    firewall_rules_forwarded_group 1
}

# firewall_rules_note COLOR TEXT — a line under the title of a part (indented
# 4), wrapped to the screen
firewall_rules_note() {
    local part
    ui_wrap_words "$2" $((UI_WIDTH - 4))
    for part in "${UI_LINES[@]}"; do printf '    %s%s%s\n' "$1" "${part//$'\x01'/ }" "${1:+$C_RESET}"; done
}

# firewall_rules_forwarded_group FILTERED — the ports forwarded to the clients
# of the VPN, in a table (FILTERED 1: the firewall runs, and does not filter
# them; 0: it does not run)
firewall_rules_forwarded_group() {
    vpn_installed || return 0
    echo
    ui_group "$(t 'Ports forwarded to the VPN clients')"
    if ((${1:-1})); then
        firewall_rules_note "$C_GREY" "$(t 'reachable from the Internet: the firewall does not filter them')"
    fi
    if ! firewall_forwarded_rows; then
        firewall_rules_note "" "$(t 'none: the VPN is not running')"
    elif ((${#FW_FORWARDED[@]} == 0)); then
        firewall_rules_note "" "$(t 'none: no client yet')"
    else
        (
            UI_WIDTH=$((UI_WIDTH - 2))
            ui_table "PORT"$'\t'"CLIENT"$'\t'"$(t 'ADDRESS')" "${FW_FORWARDED[@]}"
        ) | sed 's/^/  /'
    fi
}

# What is open, in words
firewall_summary() {
    local summary
    summary="SSH ($(firewall_ssh_ports)/tcp)"
    if vpn_installed; then summary+=", VPN ($VPN_PORT/udp)"; fi
    if seedbox_installed; then
        summary+=", $(t 'web (80, 443/tcp), BitTorrent (%s)' "$TORRENT_PORT")"
    elif links_site_on; then
        summary+=", $(t 'site of the links (80, 443/tcp)')"
    fi
    printf '%s' "$summary"
}

firewall_generate_rules() {
    local extra=""
    if vpn_installed; then
        extra+="        # WireGuard VPN, and everything coming from the clients of the VPN
        udp dport $VPN_PORT accept
        iifname \"$VPN_INTERFACE\" accept
"
    fi
    if seedbox_installed; then
        extra+="        # seedbox: web site (HTTP for Let's Encrypt, then HTTPS) and BitTorrent peers
        tcp dport { 80, 443 } accept
        meta l4proto { tcp, udp } th dport $TORRENT_PORT accept
"
    elif links_site_on; then
        extra+="        # site of the one-time links of the VPN (HTTP for Let's Encrypt, then HTTPS)
        tcp dport { 80, 443 } accept
"
    fi
    cat <<EOF
#!/usr/sbin/nft -f
# Written by seedtunnel — firewall: anything not allowed here is refused.
table inet $FIREWALL_TABLE
delete table inet $FIREWALL_TABLE
table inet $FIREWALL_TABLE {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname "lo" accept
        # ping and the ICMP messages IPv6 cannot work without; protocol
        # numbers (1 = ICMP, 58 = ICMPv6): names depend on /etc/protocols,
        # missing from some minimal images
        meta l4proto { 1, 58 } accept
        # IPv6 address obtained by DHCPv6
        ip6 saddr fe80::/10 udp dport 546 accept
        # SSH and SFTP
        tcp dport { $(firewall_ssh_ports) } accept
$extra    }
}
EOF
}

firewall_generate_unit() {
    cat <<EOF
# Written by seedtunnel — loads the firewall at boot, before the network
[Unit]
Description=seedtunnel firewall (nftables)
Wants=network-pre.target
Before=network-pre.target shutdown.target
# if nftables.service is on, its « flush ruleset » comes first, not after
After=nftables.service
Conflicts=shutdown.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $FIREWALL_RULES
ExecReload=/usr/sbin/nft -f $FIREWALL_RULES
ExecStop=-/usr/sbin/nft delete table inet $FIREWALL_TABLE

[Install]
WantedBy=sysinit.target
EOF
}

# Rules loaded + loaded again at boot + state saved
firewall_activate() {
    run 'Applying the rules' nft -f "$FIREWALL_RULES"
    pending_clear firewall
    # noted before the service loaded at boot: if enabling it fails, the next
    # « seedtunnel apply » puts it right (firewall_refresh)
    FIREWALL_ENABLED=1
    state_write "$FIREWALL_CONF_FILE" FIREWALL_ENABLED
    if write_if_changed "$FIREWALL_UNIT" 644 root:root firewall_generate_unit; then
        run 'Reloading systemd' systemctl daemon-reload
    fi
    run 'Enabling at boot' systemctl enable --now seedtunnel-firewall.service
}

# Puts the firewall back as it was before a trial: the previous rules (1) or no
# rules at all (0). Status 1 if that failed.
firewall_undo() {
    if (($1)); then
        nft -f "$FIREWALL_RULES" >>"$APP_LOG" 2>&1
    else
        # already gone (the automatic undo was faster) is fine too
        nft delete table inet "$FIREWALL_TABLE" >>"$APP_LOG" 2>&1 \
            || ! nft list table inet "$FIREWALL_TABLE" &>/dev/null
    fi
}

# The OpenSSH programs that write « Accepted … » in the journal: sshd
# (Debian 12), sshd-session and sshd-auth (Debian 13)
FIREWALL_SSHD_PROGRAMS="/usr/sbin/sshd /usr/lib/openssh/sshd-session /usr/lib/openssh/sshd-auth"

# Addresses of the server itself, IPv4 and IPv6 (one per line, without /prefix)
firewall_local_addresses() { ip -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }' || true; }

# Is the address $1 the server itself (localhost or one of its addresses)?
firewall_is_local_address() {
    [[ $1 == 127.* || $1 == ::1 ]] || grep -qxF -- "$1" <<<"$(firewall_local_addresses)"
}

# Does the session running seedtunnel come from the Internet (not through
# the VPN, not from the server itself, not from the console)?
firewall_session_from_internet() {
    local source
    source=$(ssh_session_source)
    [[ -n $source && $source != "$VPN_SUBNET".* ]] && ! firewall_is_local_address "$source"
}

# SSH logins accepted since $1 (seconds since 1970), one per line:
# « ADDRESS USER ». Only the messages written by the OpenSSH programs: journald
# notes the real program that wrote each message (_EXE), so a message written
# by another program, even one calling itself sshd, is left out. No search
# without this filter: no message from sshd, no proof.
firewall_ssh_logins() {
    local program
    local -a filters=()
    for program in $FIREWALL_SSHD_PROGRAMS; do filters+=("_EXE=$program"); done
    journalctl --since "@$1" -o cat --no-pager "${filters[@]}" 2>/dev/null \
        | sed -nE 's/^Accepted (publickey|password|keyboard-interactive)[^ ]* for ([^ ]+) from ([^ ]+) port .*/\3 \2/p' || true
}

# Proof that SSH still works with the new rules: a login accepted by sshd
# since $1. From the Internet: always counts. Through the VPN: only counts if
# the session running seedtunnel comes through the VPN too (from the Internet,
# it would prove nothing for that way; the VPN is always allowed, but this
# does not prove that its port works for a new tunnel either). Never counts:
# a login from the server itself, or of the SFTP account.
firewall_new_ssh_login() {
    local address user from_internet=0
    if firewall_session_from_internet; then from_internet=1; fi
    while read -r address user; do
        [[ -n $address ]] || continue
        if firewall_is_local_address "$address"; then continue; fi
        if ((from_internet)) && [[ $address == "$VPN_SUBNET".* ]]; then continue; fi
        if [[ $user == "${SEEDBOX_USER-}" ]]; then continue; fi
        return 0
    done < <(firewall_ssh_logins "$1")
    return 1
}

# firewall_duration SECONDS — « 1 min 32 s », « 45 s »
firewall_duration() {
    if (($1 >= 60)); then
        printf '%s min %s s' $(($1 / 60)) $(($1 % 60))
    else
        printf '%s s' "$(($1 > 0 ? $1 : 0))"
    fi
}

# What to do while the rules are on trial, in a frame: a new SSH connection.
# Through the VPN, it proves something only if this session comes through it
# too (firewall_new_ssh_login): said only when there is a VPN.
firewall_trial_box() {
    local -a lines
    lines=("$(t 'Open a NEW SSH connection to this server (another PuTTY window, for example) and log in, without closing this one: it proves that you can still get in with the firewall.')")
    if vpn_installed; then
        lines+=("$(t 'Through the public address of the server, it is always enough. Through the VPN (%s), only if this window goes through the VPN too.' "$VPN_SUBNET.1")")
    fi
    lines+=("$(t 'Without it, the firewall undoes itself in 2 minutes.')")
    ui_box info "$(t 'New SSH connection')" "${lines[@]}"
}

# « yes » without a new SSH login seen: in a red frame, with the time left
firewall_no_login_box() {
    local -a lines
    lines=("$(t 'seedtunnel has seen none since the rules were put on trial.')")
    lines+=("$(t 'Open a NEW window (keep this one), log in, then type "yes" again.')")
    if vpn_installed; then lines+=("$(t 'Through the VPN, it only counts if this window goes through the VPN too.')"); fi
    lines+=("$(t 'Time left: %s.' "$(firewall_duration "$1")")")
    ui_box bad "$(t 'No new SSH connection yet')" "${lines[@]}"
}

# « yes » keeps the rules only once a new SSH login went through them; any
# other answer, or no proof before the automatic undo, cancels
firewall_wait_confirmation() {
    local start=$1 answer left
    while :; do
        left=$((start + 110 - $(date +%s)))
        ((left > 0)) || return 1
        IFS= read -r -t "$left" -p "$(t 'Does it work? Type "yes" to keep the firewall:') " answer || return 1
        [[ ${answer,,} == yes || ${answer,,} == oui ]] || return 1
        if firewall_new_ssh_login "$start"; then return 0; fi
        echo
        firewall_no_login_box "$((start + 110 - $(date +%s)))"
        echo
    done
}

firewall_enable() {
    local was_on=0 start
    local -a undo
    banner
    section 'Enable / update the firewall'
    conflicts_refuse
    apt_install nftables
    if firewall_enabled && [[ -s $FIREWALL_RULES ]]; then was_on=1; fi
    # the new rules go to their own file: the rules in use, loaded at boot,
    # stay as they are until the new ones are confirmed
    rm -f "$FIREWALL_CANDIDATE"
    write_if_changed "$FIREWALL_CANDIDATE" 600 root:root firewall_generate_rules || true
    run 'Checking the rules' nft -c -f "$FIREWALL_CANDIDATE"
    say '  Open: %s' "$(firewall_summary)"
    echo
    if ((INTERACTIVE)); then
        # undo = back to the rules in use before, or to no rules if it was off
        if ((was_on)); then
            undo=(-f "$FIREWALL_RULES")
        else
            undo=(delete table inet "$FIREWALL_TABLE")
        fi
        say 'For safety, the firewall will undo itself in 2 minutes unless you'
        say 'confirm from a NEW SSH connection.'
        echo
        if ! confirm 'Enable the firewall?' y; then
            rm -f "$FIREWALL_CANDIDATE"
            return 0
        fi
        systemctl stop "$FIREWALL_ROLLBACK_UNIT.timer" &>/dev/null || true
        systemctl reset-failed "$FIREWALL_ROLLBACK_UNIT.timer" "$FIREWALL_ROLLBACK_UNIT.service" &>/dev/null || true
        run 'Scheduling the automatic undo (2 min)' \
            systemd-run --quiet --unit="$FIREWALL_ROLLBACK_UNIT" --on-active=120 /usr/sbin/nft "${undo[@]}"
        run 'Applying the rules (temporarily)' nft -f "$FIREWALL_CANDIDATE"
        start=$(date +%s)
        echo
        firewall_trial_box
        echo
        if firewall_wait_confirmation "$start"; then
            systemctl stop "$FIREWALL_ROLLBACK_UNIT.timer" &>/dev/null || true
            # the automatic undo must really be cancelled before the new rules
            # are kept: otherwise it would put the old ones back later
            if systemctl is-active --quiet "$FIREWALL_ROLLBACK_UNIT.timer"; then
                firewall_undo "$was_on" || true
                rm -f "$FIREWALL_CANDIDATE"
                die 'The automatic undo could not be cancelled: the previous rules are back, nothing was kept (details in %s).' "$APP_LOG"
            fi
        else
            echo
            if ! firewall_undo "$was_on"; then
                # the automatic undo stays scheduled: it tries again in 2 minutes
                die 'Putting the previous firewall back failed (details in %s). The automatic undo stays scheduled and tries again within 2 minutes.' "$APP_LOG"
            fi
            systemctl stop "$FIREWALL_ROLLBACK_UNIT.timer" &>/dev/null || true
            rm -f "$FIREWALL_CANDIDATE"
            if ((was_on)); then
                warn 'Change cancelled: the previous rules are back.'
            else
                warn 'Firewall cancelled: nothing was kept.'
            fi
            pause
            return 0
        fi
    fi
    # confirmed (or --yes): the new rules become the ones loaded at boot
    mv -f "$FIREWALL_CANDIDATE" "$FIREWALL_RULES"
    firewall_activate
    ok 'Firewall on: everything not allowed is refused.'
    pause
}

firewall_disable() {
    banner
    section 'Turn the firewall off'
    danger "$(t 'Turn the firewall off')" "$(t 'Every port of the server can then be reached from the Internet (fail2ban still bans the attacks it sees).')"
    if ! confirm 'Turn the firewall off?' n; then return 0; fi
    nft_delete_table inet "$FIREWALL_TABLE"
    # the rules must really be gone before anything is deleted
    if nft list table inet "$FIREWALL_TABLE" &>/dev/null; then
        die 'The firewall rules could not be removed (details in %s): the firewall stays on, nothing was deleted.' "$APP_LOG"
    fi
    log_run 'Stopping the firewall' systemctl disable --now seedtunnel-firewall.service
    rm -f "$FIREWALL_UNIT" "$FIREWALL_RULES" "$FIREWALL_CANDIDATE" "$FIREWALL_CONF_FILE"
    pending_clear firewall
    systemctl daemon-reload 2>/dev/null || true
    ok 'Firewall off.'
    pause
}

# Called after every change of the VPN or of the seedbox
# Puts the rules in line with the settings (port of the VPN, seedbox…). The
# new rules are applied first (nft -f takes all of them or none); the file
# loaded at boot only changes once nftables has taken them. If they are
# refused, nothing changed, and the next run tries again.
# The rules of the firewall are loaded, refuse what is not allowed, and open
# what the settings need. They can disappear, or be older ones, while their
# file stays the same: another program that empties nftables, a table removed
# by hand, a restore that brings the file of the same rules.
firewall_rules_in_force() {
    local rules
    rules=$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null) || return 1
    firewall_refuses_by_default <<<"$rules" && [[ -z $(firewall_rules_missing "$rules" 2>&1) ]]
}

firewall_refresh() {
    local next="$FIREWALL_RULES.next"
    firewall_enabled || return 0
    (umask 077 && firewall_generate_rules >"$next") || die 'Cannot write %s (disk full?).' "$next"
    if cmp -s "$next" "$FIREWALL_RULES" && ! pending firewall && firewall_rules_in_force; then
        rm -f "$next"
    else
        run 'Updating the firewall' nft -f "$next"
        mv -f "$next" "$FIREWALL_RULES"
        pending_clear firewall
    fi
    # on in the settings: also at boot (enabling it may have failed before),
    # and its service running (stopping it removes the rules)
    if write_if_changed "$FIREWALL_UNIT" 644 root:root firewall_generate_unit; then
        run 'Reloading systemd' systemctl daemon-reload
    fi
    unit_ensure_on 'Enabling at boot' seedtunnel-firewall.service
}

# --- What is wrong with the firewall, or around it ------------------------------
# The same findings for the block of the home screen, the screen Firewall and
# « seedtunnel firewall status »: the rules of seedtunnel, and what another
# program does to the traffic of the VPN (Docker most of all).

# File of nftables.service (Debian): « flush ruleset » there empties every
# rule at boot
NFTABLES_CONF="/etc/nftables.conf"

# fw_finding LEVEL SHORT TITLE LINE… — one finding: bad or warn, a few words
# for the home screen (« Docker blocks the VPN »), the title of its frame and
# its lines (texts already translated)
fw_finding() {
    local text
    FW_LEVELS+=("$1")
    FW_SHORTS+=("$2")
    FW_TITLES+=("$3")
    shift 3
    printf -v text '%s\n' "$@"
    FW_TEXTS+=("${text%$'\n'}")
}

# firewall_findings — FW_LEVELS, FW_SHORTS, FW_TITLES, FW_TEXTS: what is
# wrong, the worst first in its kind (nothing: all is right)
firewall_findings() {
    local rules missing ruleset family name allowed docker fix docker_fix panel
    FW_LEVELS=() FW_SHORTS=() FW_TITLES=() FW_TEXTS=()
    # 1: Docker blocks the VPN, or only rules typed by hand let it through
    # (the menu offers to let it through for good)
    FW_DOCKER=0
    # what puts the rules in place again, what lets the VPN through Docker:
    # the menu, or the command
    if ((INTERACTIVE)); then
        fix=$(t '[1] Enable / update the firewall')
        docker_fix=$(t '[4] Let the VPN through Docker')
    else
        fix="seedtunnel firewall enable"
        docker_fix="seedtunnel apply"
    fi
    if { vpn_installed || seedbox_installed; } && panel=$(hosting_panel); then
        fw_finding bad "$(t '%s is installed' "$panel")" "$(t '%s is installed' "$panel")" \
            "$(t '%s is a hosting panel: it already runs the web (nginx or Apache, certificates) and the security (bans, firewall) of this server.' "$panel")" \
            "$(t 'To put it right: a separate server for seedtunnel.')"
    fi
    if { vpn_installed || seedbox_installed; } && ufw_active; then
        fw_finding bad "$(t 'ufw is on')" "$(t 'ufw is on')" \
            "$(t 'ufw (the firewall of Ubuntu) blocks the VPN and the seedbox, and seedtunnel does not change its rules.')" \
            "$(t 'To put it right: sudo ufw disable, then %s.' "$fix")"
    fi
    if firewall_enabled; then
        rules=$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true)
        if [[ -z $rules ]]; then
            fw_finding bad "$(t 'see its rules')" "$(t 'Rules of the firewall missing')" \
                "$(t 'The firewall is on in the settings, but its rules are not loaded: nothing is refused.')" \
                "$(t '%s loads them again.' "$fix")"
        elif ! firewall_refuses_by_default <<<"$rules"; then
            fw_finding bad "$(t 'see its rules')" "$(t 'Rules that refuse nothing')" \
                "$(t 'The rules loaded do not refuse what is not allowed.')" \
                "$(t '%s loads them again.' "$fix")"
        else
            missing=$(firewall_rules_missing_list "$rules")
            if [[ $missing == *SSH* ]]; then
                fw_finding bad "$(t 'SSH port closed')" "$(t 'The SSH port is closed')" \
                    "$(t 'SSH listens on a port that the rules loaded do not open (%s): risk of being locked out at the next connection.' "$missing")" \
                    "$(t '%s opens it (on trial).' "$fix")"
            elif [[ -n $missing ]]; then
                fw_finding bad "$(t 'see its rules')" "$(t 'Rules incomplete')" \
                    "$(t 'Missing from the rules loaded, although the settings need it: %s.' "$missing")" \
                    "$(t '%s puts them in place.' "$fix")"
            fi
        fi
    fi
    # the traffic of the clients crosses the server: another program may
    # refuse it (doctor_vpn_forward). Docker: let through for good by the
    # service of seedtunnel (or by its own setting).
    if vpn_installed && ruleset=$(nft list ruleset 2>/dev/null); then
        while read -r family name allowed docker; do
            [[ -n $family ]] || continue
            if ((allowed)) && { ((docker == 0)) || docker_forward_drop_off || vpn_docker_on; }; then continue; fi
            if ((docker)); then FW_DOCKER=1; fi
            if ((docker && allowed)); then
                fw_finding warn "$(t 'rules for Docker temporary')" "$(t 'Temporary rules for Docker')" \
                    "$(t 'Rules added by hand let the VPN through, but they disappear at the next restart of Docker or of the server.')" \
                    "$(t 'To keep them: %s (2 rules in the chain DOCKER-USER, the one Docker keeps for your own rules, put back each time Docker starts).' "$docker_fix")"
            elif ((docker)); then
                fw_finding bad "$(t 'Docker blocks the VPN')" "$(t 'Docker blocks the VPN')" \
                    "$(t 'The devices connect to the VPN, but have no Internet: Docker, installed on this server, refuses by default the traffic that crosses it.')" \
                    "$(t 'To put it right: %s (2 rules in the chain DOCKER-USER, the one Docker keeps for your own rules, put back each time Docker starts).' "$docker_fix")"
            else
                fw_finding bad "$(t 'another program blocks the VPN')" "$(t 'Another program blocks the VPN')" \
                    "$(t 'The rules of another program (table %s) refuse the traffic that crosses the server: the devices connect to the VPN, but have no Internet.' "$family $name")" \
                    "$(t 'They must accept what comes in by %s and what goes back to it. seedtunnel does not touch the rules of other programs.' "$VPN_INTERFACE")"
            fi
        done < <(forward_drop_tables "$VPN_INTERFACE" <<<"$ruleset")
    fi
    if systemctl is-enabled --quiet nftables.service 2>/dev/null && grep -qs 'flush ruleset' "$NFTABLES_CONF"; then
        fw_finding warn "$(t 'nftables empties the rules at boot')" "$(t 'nftables empties the rules')" \
            "$(t 'nftables.service is on, and its file %s deletes every rule when the server starts: those of seedtunnel can disappear.' "$NFTABLES_CONF")" \
            "$(t 'If you do not use it yourself:  sudo systemctl disable nftables')"
    fi
}

# The findings: in frames in the menus, as lines for the commands
firewall_findings_show() {
    local i line
    local -a lines
    for i in "${!FW_LEVELS[@]}"; do
        if ((i > 0)); then echo; fi
        if ((INTERACTIVE)); then
            mapfile -t lines <<<"${FW_TEXTS[i]}"
            ui_box "${FW_LEVELS[i]}" "${FW_TITLES[i]}" "${lines[@]}"
        else
            if [[ ${FW_LEVELS[i]} == bad ]]; then
                printf '%s✘ %s%s\n' "$C_RED" "${FW_TITLES[i]}" "$C_RESET"
            else
                printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "${FW_TITLES[i]}"
            fi
            while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"${FW_TEXTS[i]}"
        fi
    done
}

# The state of the firewall at the top of its screen and for « seedtunnel
# firewall status », then what is wrong
firewall_status() {
    local rules
    firewall_findings
    if firewall_enabled; then
        rules=$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true)
        if [[ -n $rules ]] && firewall_refuses_by_default <<<"$rules"; then
            ui_print_wrapped "$C_GREEN✔$C_RESET " "  " "$(t 'Firewall on — open: %s' "$(firewall_summary)")"
        fi
    else
        say 'seedtunnel firewall off (everything is open, apart from the fail2ban rules).'
    fi
    if ((${#FW_LEVELS[@]})); then
        echo
        firewall_findings_show
    fi
}

firewall_menu() {
    local choice
    while true; do
        UI_PLACE=("$(t 'Firewall')")
        ui_top "${UI_PLACE[@]}"
        firewall_status
        echo
        ui_menu_add 1 "$(t 'Enable / update the firewall')"
        ui_menu_add 2 "$(t 'Turn the firewall off')"
        ui_menu_add 3 "$(t 'Show the rules')"
        # only when Docker blocks the VPN (firewall_findings, just above)
        if ((FW_DOCKER)); then ui_menu_add 4 "$(t 'Let the VPN through Docker')"; fi
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action firewall_enable ;;
            2) ui_action firewall_disable ;;
            3) ui_action firewall_rules_menu ;;
            4) if ((FW_DOCKER)); then ui_action vpn_docker_menu; fi ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# seedtunnel firewall <command>
firewall_cli() {
    cli_takes 1 "firewall${1:+ $1}" "$@"
    case ${1-} in
        "")
            require_terminal
            firewall_menu
            ;;
        enable)
            # in a terminal: enabled with the automatic undo
            if [[ -t 0 ]] && ((!OPT_YES)); then
                INTERACTIVE=1
            elif ((!OPT_YES)); then
                die 'Without a terminal:  seedtunnel firewall enable --yes'
            fi
            firewall_enable
            ;;
        disable) firewall_disable ;;
        status) firewall_status ;;
        rules)
            firewall_rules_show
            echo
            say 'Raw rules:  nft list table inet %s ; nft list table ip seedtunnel' "$FIREWALL_TABLE"
            ;;
        *) die 'Usage: seedtunnel firewall enable|disable|status|rules' ;;
    esac
}
