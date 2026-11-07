#!/usr/bin/env bash
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

# SSH ports: those of sshd, plus the one of the current connection (just in case)
firewall_ssh_ports() {
    local settings ports
    settings=$(sshd -T 2>/dev/null || true)
    ports=$(awk '$1 == "port" { print $2 }' <<<"$settings")
    if [[ -n ${SSH_CONNECTION-} ]]; then ports+=$'\n'"${SSH_CONNECTION##* }"; fi
    ports=$(awk '/^[0-9]+$/ && !seen[$0]++' <<<"$ports" | paste -sd, -)
    ports=${ports:-22}
    printf '%s' "${ports//,/, }"
}

# Ports on which SSH really listens, plus those of its configuration (used at
# the next restart of SSH)
firewall_sshd_ports() {
    {
        sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
        ss -Hltnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
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
            "ct state established,related accept") firewall_rule_line "$(t 'Replies to the connections already open')" ;;
            'iifname "lo" accept') firewall_rule_line "$(t 'The server talking to itself')" ;;
            "iifname \"$VPN_INTERFACE\" accept") firewall_rule_line "$(t 'Everything coming from the VPN clients')" ;;
            "ip6 saddr fe80::/10 udp dport 546 accept") firewall_rule_line "$(t 'IPv6 address given by the provider (DHCPv6)')" ;;
            "meta l4proto {"*"} accept")
                if [[ $line == *icmp* || $line == *"1, 58"* ]]; then
                    firewall_rule_line "$(t 'Ping and ICMP messages (IPv4 and IPv6)')"
                else
                    printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t 'Other rule: %s' "$line")"
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
                if [[ -n $ssh ]]; then firewall_rule_line "$(t 'SSH / SFTP: port %s/tcp' "$ssh")"; fi
                if [[ -n $web ]]; then firewall_rule_line "$(t 'Web site: ports %s/tcp' "$web")"; fi
                if [[ -n $other ]]; then printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t 'Other port open: %s/tcp' "$other")"; fi
                ;;
            "udp dport "*" accept")
                port=$(firewall_rule_numbers "$line")
                if vpn_installed && [[ $port == "$VPN_PORT" ]]; then
                    firewall_rule_line "$(t 'VPN WireGuard: port %s/udp' "$port")"
                else
                    printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t 'Other port open: %s/udp' "$port")"
                fi
                ;;
            "meta l4proto { "*" } th dport "*" accept")
                port=$(firewall_rule_numbers "$line")
                if seedbox_installed && [[ $port == "$TORRENT_PORT" ]]; then
                    firewall_rule_line "$(t 'BitTorrent: port %s (TCP and UDP)' "$port")"
                else
                    printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t 'Other port open: %s (TCP and UDP)' "$port")"
                fi
                ;;
            *) printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t 'Other rule: %s' "$line")" ;;
        esac
    done
}

# Ports the settings want open but that the loaded rules ($1) do not have
firewall_rules_missing() {
    local rules=$1 port missing="" open
    open=" $(firewall_open_tcp_ports <<<"$rules" | paste -sd' ' -) "
    for port in $(firewall_ssh_ports | tr -d ','); do
        if [[ $open != *" $port "* ]]; then missing+="${missing:+, }SSH $port/tcp"; fi
    done
    if vpn_installed && ! grep -qE "udp dport $VPN_PORT accept" <<<"$rules"; then missing+="${missing:+, }VPN $VPN_PORT/udp"; fi
    if seedbox_installed; then
        for port in 80 443; do
            if [[ $open != *" $port "* ]]; then missing+="${missing:+, }web $port/tcp"; fi
        done
        if ! grep -qE "th dport $TORRENT_PORT accept" <<<"$rules"; then missing+="${missing:+, }BitTorrent $TORRENT_PORT"; fi
    fi
    if [[ -n $missing ]]; then
        err 'Missing from the rules loaded, although the settings need it: %s   → seedtunnel apply' "$missing"
    fi
}

# Ports forwarded to the clients of the VPN (NAT of the VPN, loaded right now)
firewall_forwarded_ports() {
    local nat line port address number name file found=0
    nat=$(nft list table ip seedtunnel 2>/dev/null || true)
    while IFS= read -r line; do
        [[ $line =~ th\ dport\ ([0-9]+)\ dnat\ (ip\ )?to\ ([0-9.]+) ]] || continue
        port=${BASH_REMATCH[1]}
        address=${BASH_REMATCH[3]}
        # client number N: address 10.8.0.(N+1), port 60000+N
        number=$((${address##*.} - 1))
        name="?"
        for file in "$VPN_CLIENTS_DIR"/*.env; do
            [[ -e $file ]] || continue
            if [[ $(vpn_client_number "$file") == "$number" ]]; then
                name=${file##*/}
                name=${name%.env}
            fi
        done
        printf '  %s●%s %s\n' "$C_GREEN" "$C_RESET" "$(t 'port %s (TCP and UDP) → %s (%s)' "$port" "$name" "$address")"
        found=1
    done <<<"$nat"
    if [[ -z $nat ]]; then
        printf '  %s\n' "$(t 'none: the VPN is not running')"
    elif ((!found)); then
        printf '  %s\n' "$(t 'none: no client yet')"
    fi
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

# From the menu: the list, then the raw rules on request
firewall_rules_menu() {
    banner
    section 'Show the rules'
    firewall_rules_show
    echo
    if confirm 'Show the raw rules (nftables)?' n; then
        echo
        nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true
        nft list table ip seedtunnel 2>/dev/null || true
    fi
    pause
}

# What is open, in words
firewall_summary() {
    local summary
    summary="SSH ($(firewall_ssh_ports)/tcp)"
    if vpn_installed; then summary+=", VPN ($VPN_PORT/udp)"; fi
    if seedbox_installed; then summary+=", $(t 'web (80, 443/tcp), BitTorrent (%s)' "$TORRENT_PORT")"; fi
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
        warn 'No new SSH login was seen since the rules were applied: open a NEW SSH connection to this server, then type "yes" again. From the Internet it always counts; through the VPN, only if this session goes through the VPN too.'
    done
}

firewall_enable() {
    local was_on=0 start
    local -a undo
    banner
    section 'Enable / update the firewall'
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
        say 'Now open a NEW SSH connection to this server, without closing this one.'
        say 'From the Internet it always counts; through the VPN, only if this session goes through the VPN too.'
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
firewall_refresh() {
    local next="$FIREWALL_RULES.next"
    firewall_enabled || return 0
    (umask 077 && firewall_generate_rules >"$next") || die 'Cannot write %s (disk full?).' "$next"
    if cmp -s "$next" "$FIREWALL_RULES" && ! pending firewall; then
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

firewall_status() {
    local rules
    if firewall_enabled; then
        rules=$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true)
        if [[ -z $rules ]]; then
            warn 'Firewall enabled but rules missing:  seedtunnel firewall enable --yes'
        elif ! firewall_refuses_by_default <<<"$rules"; then
            warn 'Firewall rules loaded, but they do not refuse what is not allowed:  seedtunnel firewall enable --yes'
        else
            ok 'Firewall on — open: %s' "$(firewall_summary)"
        fi
    else
        say 'seedtunnel firewall off (everything is open, apart from the fail2ban rules).'
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
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action firewall_enable ;;
            2) ui_action firewall_disable ;;
            3) ui_action firewall_rules_menu ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# seedtunnel firewall <command>
firewall_cli() {
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
