#!/usr/bin/env bash
# =============================================================================
#  seedtunnel — diagnostics (« seedtunnel doctor »)
#
#  Checks in one go what causes most breakdowns: stopped services, DNS not
#  pointing to the server, certificate about to expire, closed port, full
#  disk, wrong clock, missing backups… Each line says what to do.
#  Exit status: 0 if there is no problem, 1 otherwise (usable in a script).
#  It changes nothing, so it also runs while a menu is open elsewhere.
# =============================================================================

DOCTOR_ERRORS=0
DOCTOR_WARNINGS=0

doctor_ok() { ok "$@"; }
doctor_warn() {
    DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
    printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t "$@")"
}
doctor_error() {
    DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1))
    printf '%s✘%s %s\n' "$C_RED" "$C_RESET" "$(t "$@")"
}
doctor_title() { printf '\n%s%s%s\n' "$C_BOLD" "$(t "$@")" "$C_RESET"; }

# doctor_service SERVICE "Name shown"
doctor_service() {
    if systemctl is-active --quiet "$1"; then
        doctor_ok '%s: running' "$2"
    else
        doctor_error '%s: stopped   → journalctl -u %s -n 30' "$2" "$1"
    fi
}

# Days left before a certificate expires (empty if unreadable)
certificate_days_left() {
    local end expires now
    end=$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    [[ -n $end ]] || return 0
    expires=$(date -d "$end" +%s 2>/dev/null) || return 0
    now=$(date +%s)
    printf '%s' "$(((expires - now) / 86400))"
}

doctor_system() {
    local free synced
    doctor_title 'System'
    doctor_ok '%s, seedtunnel %s' "$APP_OS_DESCRIPTION" "$APP_VERSION"
    free=$(disk_free_gb /)
    if [[ -z $free ]]; then
        doctor_warn 'Free space of / unreadable'
    elif ((free < 2)); then
        doctor_error 'Disk almost full: %s GB free on /' "$free"
    else
        doctor_ok 'Free space on /: %s GB' "$free"
    fi
    if grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
        doctor_ok 'Automatic security updates on'
    else
        doctor_warn 'Automatic security updates off'
    fi
    if [[ -f $NET_HARDENING_FILE ]]; then
        if net_hardening_in_force; then
            doctor_ok 'Kernel network settings hardened'
        else
            doctor_warn 'Kernel network settings not applied   → seedtunnel apply'
        fi
    fi
    # left by an update cut short (power cut…): the next update refuses to run
    if [[ -e $APP_DIR.previous ]]; then
        doctor_warn 'An update did not finish: %s is still there. If seedtunnel works, delete it:  rm -rf %s' "$APP_DIR.previous" "$APP_DIR.previous"
    fi
    doctor_restore_interrupted
    if [[ -e /run/reboot-required ]]; then
        doctor_warn 'Restart advised (update of the kernel or of a library)'
    fi
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    if [[ $synced == yes ]]; then
        doctor_ok 'Clock synchronized'
    else
        doctor_warn 'Clock not synchronized: certificates and WireGuard depend on it (timedatectl)'
    fi
}

doctor_vpn() {
    local ip=$1 ips
    doctor_title 'WireGuard VPN'
    doctor_service "wg-quick@$VPN_INTERFACE" 'WireGuard service'
    if [[ $(wg show "$VPN_INTERFACE" listen-port 2>/dev/null || true) == "$VPN_PORT" ]]; then
        doctor_ok 'Listening on port %s/udp' "$VPN_PORT"
    else
        doctor_error 'WireGuard is not listening on port %s/udp   → seedtunnel vpn restart' "$VPN_PORT"
    fi
    if [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 1 ]]; then
        doctor_ok 'IPv4 routing on'
    else
        doctor_error 'IPv4 routing off: the clients will have no Internet   → seedtunnel apply'
    fi
    doctor_vpn_nat
    if is_ipv4 "$VPN_PUBLIC_ADDRESS"; then
        if [[ $VPN_PUBLIC_ADDRESS == "$ip" ]]; then
            doctor_ok 'Address of the clients (%s) = public IP of the server' "$VPN_PUBLIC_ADDRESS"
        else
            doctor_warn 'The clients connect to %s, but the public IP is %s' "$VPN_PUBLIC_ADDRESS" "${ip:-$(t 'unknown')}"
        fi
    else
        ips=$(dns_ipv4_addresses "$VPN_PUBLIC_ADDRESS")
        if [[ -n $ip ]] && grep -qxF "$ip" <<<"$ips"; then
            doctor_ok '"%s" points to this server' "$VPN_PUBLIC_ADDRESS"
        else
            doctor_warn '"%s" points to %s and not to %s' "$VPN_PUBLIC_ADDRESS" "${ips:-$(t 'nothing')}" "${ip:-$(t 'this server')}"
        fi
    fi
    doctor_ok 'Clients: %s, %s connected right now' "$(vpn_count_clients)" "$(vpn_connected_count)"
    say "  (the UDP port cannot be tested from outside by the server itself: if in"
    say "   doubt, check the firewall in the control panel of the provider)"
}

# Left by a restore cut short (power cut…): the settings may be half there.
# Back to those from before it, if there were some; otherwise, restore again.
doctor_restore_interrupted() {
    local previous
    restore_interrupted || return 0
    previous=$(restore_interrupted_previous)
    if [[ -n $previous && -d $previous ]]; then
        doctor_error 'A restore did not finish: the settings of seedtunnel may be incomplete. To go back to those from before it:  rm -rf %s && mv %s %s && rm -f %s && seedtunnel apply' \
            "$APP_STATE_DIR" "$previous" "$APP_STATE_DIR" "$RESTORE_MARKER"
    else
        doctor_error 'A restore did not finish: the settings of seedtunnel may be incomplete. Run it again:  seedtunnel restore FILE'
    fi
}

# The clients go out to the Internet through the masquerade rule: it must be
# there, for the network of the VPN, and use the network interface the server
# uses now (it may have changed: new server, other name after an upgrade)
doctor_vpn_nat() {
    local rules interface
    rules=$(nft list table ip seedtunnel 2>/dev/null || true)
    interface=$(default_interface)
    if [[ -z $rules ]]; then
        doctor_error 'NAT rules missing   → seedtunnel vpn restart'
    elif ! grep -qF "ip saddr $VPN_SUBNET.0/24 oifname \"$interface\" masquerade" <<<"$rules"; then
        doctor_error 'NAT rules not made for the network interface of the server (%s): the clients have no Internet   → seedtunnel apply' "${interface:-?}"
    else
        doctor_ok 'NAT rules in place'
    fi
}

# Transmission, or why the full disk protection keeps it stopped
doctor_transmission() {
    local free
    if ! diskguard_stopped; then
        doctor_service transmission-daemon 'Transmission'
        return 0
    fi
    free=$(disk_free_gb "$SEEDBOX_DATA_DIR")
    if diskguard_start_failed; then
        doctor_error 'Transmission does not start again although there is room (%s GB free)   → journalctl -u transmission-daemon -n 30' "${free:-?}"
    else
        doctor_error 'Transmission stopped: disk almost full (%s GB free). Free some space: it restarts by itself above %s GB.' \
            "${free:-?}" "$DISKGUARD_START_ABOVE_GB"
    fi
}

# The certificate served, as a browser sees it through the public IP: chain,
# name and dates checked (no -k). A valid certificate on the disk is not
# enough: nginx may still serve an older one, or another one. Only for Let's
# Encrypt (the self-signed one and the test servers are refused by design).
doctor_certificate_served() {
    local ip=$1 rc=0
    [[ $SEEDBOX_CERTIFICATE == letsencrypt ]] || return 0
    curl -s -o /dev/null --max-time 8 --resolve "$SEEDBOX_DOMAIN:443:$ip" "https://$SEEDBOX_DOMAIN/" 2>/dev/null || rc=$?
    case $rc in
        0) doctor_ok 'Certificate accepted by browsers for %s' "$SEEDBOX_DOMAIN" ;;
        # TLS failures: handshake, name, certificate, chain
        35 | 51 | 58 | 60) doctor_error 'The certificate served for %s is refused by browsers (curl code %s)   → seedtunnel seedbox domain %s' "$SEEDBOX_DOMAIN" "$rc" "$SEEDBOX_DOMAIN" ;;
        # connection refused, timeout…: the certificate could not be seen
        *) doctor_warn 'Certificate served for %s not checked: HTTPS unreachable through the public IP (curl code %s)' "$SEEDBOX_DOMAIN" "$rc" ;;
    esac
}

doctor_seedbox() {
    local ip=$1 crt days code free settings
    doctor_title 'Seedbox'
    doctor_transmission
    doctor_service nginx 'nginx'
    doctor_service fail2ban 'fail2ban'
    doctor_service ssh.service 'SSH / SFTP'
    if systemctl is-active --quiet seedtunnel-diskguard.timer; then
        doctor_ok 'Full disk protection on (Transmission stopped under %s GB free)' "$DISKGUARD_STOP_BELOW_GB"
    else
        doctor_warn 'Full disk protection off   → seedtunnel apply'
    fi

    if is_ipv4 "$SEEDBOX_DOMAIN"; then
        doctor_warn 'No domain name (access by IP, self-signed certificate)'
    elif dns_points_here "$SEEDBOX_DOMAIN" "$ip"; then
        doctor_ok '"%s" points to this server (%s)' "$SEEDBOX_DOMAIN" "$ip"
    else
        doctor_error '"%s" does not point to this server (%s): check the DNS' "$SEEDBOX_DOMAIN" "${ip:-$(t 'IP unknown')}"
    fi

    if [[ $SEEDBOX_CERTIFICATE == selfsigned ]]; then crt="$SEEDBOX_SSL_DIR/selfsigned.crt"; else crt="$LETSENCRYPT_DIR/cert.pem"; fi
    days=$(certificate_days_left "$crt")
    if [[ -z $days ]]; then
        doctor_error 'Certificate unreadable: %s   → seedtunnel seedbox domain %s' "$crt" "$SEEDBOX_DOMAIN"
    elif [[ $SEEDBOX_CERTIFICATE == selfsigned ]]; then
        doctor_warn 'Self-signed certificate (browser warning)   → seedtunnel seedbox domain %s' "$SEEDBOX_DOMAIN"
    elif ((days < 7)); then
        doctor_error "Let's Encrypt certificate: expires in %s day(s), the renewal fails   → certbot renew" "$days"
    elif ((days < 21)); then
        doctor_warn "Let's Encrypt certificate: expires in %s days (it should have been renewed)" "$days"
    else
        doctor_ok 'Certificate %s: %s days left' "$(seedbox_certificate_label)" "$days"
    fi
    if [[ $SEEDBOX_CERTIFICATE != selfsigned ]]; then
        if systemctl is-active --quiet certbot.timer; then
            doctor_ok 'Automatic renewal scheduled (certbot.timer)'
        else
            doctor_error 'certbot.timer inactive: the certificate will not be renewed   → systemctl enable --now certbot.timer'
        fi
    fi

    code=$(seedbox_http_code /transmission/web/)
    if [[ $code == 401 ]]; then
        doctor_ok 'Web interface online and protected by a password'
    else
        doctor_error 'Web interface: unexpected answer (code %s) on %s' "${code:-$(t 'none')}" "https://$SEEDBOX_DOMAIN/"
    fi
    if [[ -n $ip ]]; then
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
            --resolve "$SEEDBOX_DOMAIN:443:$ip" "https://$SEEDBOX_DOMAIN/transmission/web/" 2>/dev/null || true)
        if [[ $code == 401 ]]; then
            doctor_ok 'HTTPS reachable through the public IP (tested from the server itself)'
        else
            doctor_warn 'HTTPS unreachable through the public IP %s (code %s): firewall?' "$ip" "${code:-$(t 'none')}"
        fi
        doctor_certificate_served "$ip"
    fi

    if seedbox_sftp_rule_applies; then
        doctor_ok 'SFTP locked in %s' "$SEEDBOX_DATA_DIR"
    else
        doctor_error 'SFTP rule inactive for %s   → seedtunnel apply' "$SEEDBOX_USER"
    fi
    if seedbox_check_data_dir "$SEEDBOX_DATA_DIR" 2>/dev/null; then
        doctor_ok 'Permissions of the data folder correct'
    else
        doctor_error 'Permissions of the folder %s incompatible with the locked SFTP' "$SEEDBOX_DATA_DIR"
    fi
    free=$(disk_free_gb "$SEEDBOX_DATA_DIR")
    if [[ -z $free ]]; then
        doctor_warn 'Free space for downloads unreadable (%s)' "$SEEDBOX_DATA_DIR"
    elif ((free < 5)); then
        doctor_warn 'Little space left for downloads: %s GB free' "$free"
    else
        doctor_ok 'Free space for downloads: %s GB' "$free"
    fi
    settings=$(fail2ban-client status 2>/dev/null || true)
    if [[ $settings == *sshd* && $settings == *nginx-http-auth* && $settings == *recidive* ]]; then
        doctor_ok 'fail2ban watches SSH, the web interface and repeat offenders'
    else
        doctor_warn 'fail2ban rules incomplete   → seedtunnel seedbox restart'
    fi
}

doctor_firewall() {
    local rules port open
    doctor_title 'Firewall'
    if firewall_enabled; then
        rules=$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true)
        if [[ -z $rules ]]; then
            doctor_error 'Firewall enabled but rules missing   → seedtunnel firewall enable --yes'
        elif ! firewall_refuses_by_default <<<"$rules"; then
            doctor_error 'Firewall rules loaded, but they do not refuse what is not allowed   → seedtunnel firewall enable --yes'
        else
            doctor_ok 'On — open: %s' "$(firewall_summary)"
            # SSH port changed without updating the firewall: one would be
            # locked out at the next connection (or the next restart of SSH)
            open=" $(firewall_open_tcp_ports <<<"$rules" | tr '\n' ' ') "
            for port in $(firewall_sshd_ports); do
                if [[ $open == *" $port "* ]]; then
                    doctor_ok 'SSH port %s open in the firewall' "$port"
                else
                    doctor_error 'SSH uses port %s, closed by the firewall: risk of being locked out   → seedtunnel firewall enable' "$port"
                fi
            done
        fi
    else
        doctor_warn 'seedtunnel firewall off   → seedtunnel firewall enable'
    fi
    if systemctl is-enabled --quiet nftables.service 2>/dev/null \
        && grep -qs 'flush ruleset' /etc/nftables.conf; then
        doctor_warn 'nftables.service is enabled and empties all the rules at boot (/etc/nftables.conf)'
    fi
}

doctor_backup() {
    local latest age since
    doctor_title 'Backups'
    if backup_auto_enabled; then
        # what the weekly backup needs to run on its own
        if ! systemctl is-active --quiet seedtunnel-backup.timer 2>/dev/null; then
            doctor_error 'Weekly backup on, but its timer is stopped: no backup will be made   → seedtunnel apply'
        fi
        if [[ ! -s $BACKUP_PASSPHRASE_FILE ]]; then
            doctor_error 'The passphrase of the weekly backup is missing: the backups will fail   → seedtunnel backup auto on'
        elif ! secret_file_private "$BACKUP_PASSPHRASE_FILE"; then
            doctor_error 'The passphrase of the weekly backup can be read by others than root   → chmod 600 %s' "$BACKUP_PASSPHRASE_FILE"
        fi
        latest=$(ls -1t "$BACKUP_DIR"/*-auto.tar.gz.enc 2>/dev/null | head -n 1 || true)
        age=$(file_age_days "$latest")
        if systemctl is-failed --quiet seedtunnel-backup.service 2>/dev/null; then
            doctor_warn 'The last automatic backup failed   → journalctl -u seedtunnel-backup'
        elif [[ -z $age ]]; then
            # turned on when its passphrase was saved
            since=$(file_age_days "$BACKUP_PASSPHRASE_FILE")
            if [[ -n $since ]] && ((since > 8)); then
                doctor_warn 'No automatic backup since it was turned on %s days ago   → journalctl -u seedtunnel-backup' "$since"
            else
                doctor_ok 'Weekly backup on (the first one comes within a week)'
            fi
        elif ((age > 8)); then
            doctor_warn 'Last automatic backup %s days ago: the weekly backup seems to fail   → journalctl -u seedtunnel-backup' "$age"
        else
            doctor_ok 'Weekly backup on, last one %s' "$(days_ago "$age")"
        fi
    else
        doctor_warn 'Weekly backup off   → seedtunnel backup auto on'
    fi
    age=$(file_age_days "$BACKUP_DOWNLOADED_MARK")
    if [[ -z $age ]]; then
        doctor_warn 'No backup downloaded to your computer yet   → seedtunnel backup share'
    elif ((age > 30)); then
        doctor_warn 'Last download of a backup started %s days ago   → seedtunnel backup share' "$age"
    else
        # only the start of the download is known, not that it went to the end
        doctor_ok 'Download of a backup started %s (check its size on your computer)' "$(days_ago "$age")"
    fi
}

doctor_main() {
    local ip
    DOCTOR_ERRORS=0
    DOCTOR_WARNINGS=0
    banner
    section 'DIAGNOSTICS'
    printf '%s ' "$(t 'Looking for the public IP address…')"
    ip=$(public_ipv4)
    echo "${ip:-$(t 'not found')}"
    doctor_system
    if vpn_installed; then doctor_vpn "$ip"; fi
    if seedbox_installed; then doctor_seedbox "$ip"; fi
    doctor_firewall
    if vpn_installed || seedbox_installed; then doctor_backup; fi
    echo
    if ((DOCTOR_ERRORS)); then
        err '%s problem(s), %s warning(s).' "$DOCTOR_ERRORS" "$DOCTOR_WARNINGS"
    elif ((DOCTOR_WARNINGS)); then
        warn 'No blocking problem, %s warning(s).' "$DOCTOR_WARNINGS"
    else
        ok 'Everything is fine.'
    fi
    # a report to send to someone who helps: asked from the menu, done with --link
    if ((OPT_LINK)); then
        echo
        report_send
    elif ((INTERACTIVE)); then
        echo
        if report_by_link; then
            if confirm 'Create a one-time link to send this report? Domain, name of the server, public IP addresses, SFTP account, SSH keys and names of the VPN clients are replaced.' n; then report_send; fi
        elif confirm 'Save this report to send it? Domain, name of the server, public IP addresses, SFTP account, SSH keys and names of the VPN clients are replaced.' n; then
            report_send
        fi
    fi
    pause
}

# --- Report to send for help (« seedtunnel doctor --link ») -----------------------
# The diagnostics and the end of the log in one text file, where what is
# private is replaced by a generic word: domain, name of the server, public IP
# addresses, SFTP account, SSH keys, names of the VPN clients. The ports and
# the addresses of the VPN (10.8.0.x, the same on every server) stay: they
# help. Passwords, passphrases and private keys never go into the log.
REPORT_LOG_LINES=500
# names (of the server, the SFTP account, the clients) that are also common
# words of a report: kept, they say nothing about anyone (« debian » would
# change « debian-transmission » too, a client « vpn » every « vpn »)
REPORT_COMMON_WORDS=" backup client clients debian firewall localhost nginx root seedbox seedtunnel server sftp ssh transmission vpn vps web wg0 "
REPORT_SCRIPT=""

report_common_word() { [[ $REPORT_COMMON_WORDS == *" ${1,,} "* ]]; }

# One known private value, as « length<TAB>value<TAB>replacement »: they are
# replaced longest first (the client « neil-laptop » before the account « neil »)
report_known() {
    if [[ -n $1 ]]; then printf '%s\t%s\t%s\n' "${#1}" "$1" "$2"; fi
}

# A link needs the site of the seedbox; otherwise the report is saved
report_by_link() { seedbox_installed && systemctl is-active --quiet nginx; }

# Adds to the sed script: the whole VALUE (not inside a longer word) →
# REPLACEMENT. Twice: two values next to each other share the character
# between them. An IPv4 address is not part of a version number either:
# « 4.23.9.0-2+b1 » (package) or « 1.2.3.4.5 » stay as they are.
report_replace() {
    local value=$1 replacement=$2 pattern before="(^|[^[:alnum:]_])" after="([^[:alnum:]_]|\$)"
    [[ -n $value ]] || return 0
    if is_ipv4 "$value"; then
        before="(^|[^[:alnum:]_.])"
        after="([^[:alnum:]_.~+-]|\\.([^0-9]|\$)|\$)"
    fi
    pattern="$before$(sed 's/[][\.*^$/+?(){}|]/\\&/g' <<<"$value")$after"
    REPORT_SCRIPT+="s/$pattern/\\1$replacement\\2/g;s/$pattern/\\1$replacement\\2/g;"
}

# Public addresses only: the private networks (10.x of the VPN, 192.168.x…)
# say nothing about anyone
report_ipv4_is_public() {
    local a b _rest
    IFS=. read -r a b _rest <<<"$1"
    if ((a == 0 || a == 10 || a == 127 || a >= 224)); then return 1; fi
    if ((a == 100 && b >= 64 && b <= 127)) || ((a == 169 && b == 254)); then return 1; fi
    if ((a == 172 && b >= 16 && b <= 31)) || ((a == 192 && b == 168)); then return 1; fi
}
report_ipv6_is_public() {
    local address=${1,,}
    [[ $address != fe80:* && $address != fc* && $address != fd* && $address != ::* ]]
}

# Public addresses of this server: of its interfaces, and the one of the VPN
# (its private ones, like 10.8.0.1 in the VPN, stay: the same everywhere)
report_server_addresses() {
    local address
    while IFS= read -r address; do
        if { is_ipv4 "$address" && report_ipv4_is_public "$address"; } \
            || { is_ipv6 "$address" && report_ipv6_is_public "$address"; }; then
            printf '%s\n' "$address"
        fi
    done < <(
        ip -o addr show scope global 2>/dev/null | awk '{ sub("/.*", "", $4); print $4 }' || true
        if is_ipv4 "${VPN_PUBLIC_ADDRESS-}" || is_ipv6 "${VPN_PUBLIC_ADDRESS-}"; then printf '%s\n' "$VPN_PUBLIC_ADDRESS"; fi
        if is_ipv4 "${SEEDBOX_DOMAIN-}"; then printf '%s\n' "$SEEDBOX_DOMAIN"; fi
    )
}

# The private values seedtunnel knows, with what replaces them (report_known)
report_known_values() {
    local file=$1 host fqdn address name number client
    if seedbox_installed && ! is_ipv4 "$SEEDBOX_DOMAIN"; then report_known "$SEEDBOX_DOMAIN" "$(t '<domain>')"; fi
    if vpn_installed && ! is_ipv4 "$VPN_PUBLIC_ADDRESS" && ! is_ipv6 "$VPN_PUBLIC_ADDRESS"; then
        report_known "$VPN_PUBLIC_ADDRESS" "$(t '<domain>')"
    fi
    fqdn=$(hostname -f 2>/dev/null || true)
    host=$(hostname 2>/dev/null || true)
    host=${host%%.*}
    if [[ $fqdn == *.* ]]; then report_known "$fqdn" "$(t '<server>')"; fi
    if ! report_common_word "$host"; then report_known "$host" "$(t '<server>')"; fi
    while IFS= read -r address; do
        report_known "$address" "$(t '<server-ip>')"
    done < <(report_server_addresses | sort -u)
    if seedbox_installed && ! report_common_word "$SEEDBOX_USER"; then report_known "$SEEDBOX_USER" "$(t '<sftp-user>')"; fi
    # each client by its number: the same in every report, as its address
    # 10.8.0.(N+1) and its port 60000+N
    for client in "$VPN_CLIENTS_DIR"/*.env; do
        [[ -e $client ]] || continue
        name=${client##*/}
        name=${name%.env}
        number=$(vpn_client_number "$client")
        if ! report_common_word "$name"; then report_known "$name" "$(t '<client-%s>' "$number")"; fi
    done
    # clients removed since, as the log names them: their link, their files
    while IFS= read -r name; do
        if [[ ! -e $VPN_CLIENTS_DIR/$name.env ]] && ! report_common_word "$name"; then
            report_known "$name" "$(t '<former-client>')"
        fi
    done < <(grep -oE '(download link for |clients/)[A-Za-z0-9_-]+\.(conf|env)' "$file" \
        | sed -E 's/^(download link for |clients\/)//; s/\.(conf|env)$//' | sort -u || true)
}

# Replaces what is private in FILE
report_anonymize() {
    local file=$1 _length value replacement address
    # colors first, then the known values, longest first (the name of the
    # server is often part of a domain, an account part of a client name)
    REPORT_SCRIPT='s/\x1b\[[0-9;]*m//g;'
    while IFS=$'\t' read -r _length value replacement; do
        report_replace "$value" "$replacement"
    done < <(report_known_values "$file" | sort -t $'\t' -k1,1nr)
    # SSH public keys with their comment, and fingerprints
    REPORT_SCRIPT+='s/(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+\/=]+( [^ ]+)?/'"$(t '<ssh-key>')"'/g;'
    REPORT_SCRIPT+='s/SHA256:[A-Za-z0-9+\/]{43}/'"$(t '<fingerprint>')"'/g;'
    sed -E -i "$REPORT_SCRIPT" "$file"
    # the other public addresses, as found in what is left
    REPORT_SCRIPT=""
    while IFS= read -r address; do
        if is_ipv4 "$address" && report_ipv4_is_public "$address"; then report_replace "$address" "$(t '<ip>')"; fi
    done < <(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$file" | sort -u || true)
    while IFS= read -r address; do
        if is_ipv6 "$address" && report_ipv6_is_public "$address"; then report_replace "$address" "$(t '<ip>')"; fi
    done < <(grep -oiE '([0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}' "$file" | sort -u || true)
    if [[ -n $REPORT_SCRIPT ]]; then sed -E -i "$REPORT_SCRIPT" "$file"; fi
}

# Writes the report into FILE: the diagnostics run again, without colors
report_generate() {
    local file=$1
    {
        t 'seedtunnel report of %s' "$(date '+%F %R %Z')"
        printf '\nseedtunnel %s · %s\n' "$APP_VERSION" "${APP_OS_DESCRIPTION:-Debian}"
        t 'Replaced: domain, name of the server, public IP addresses, SFTP account, SSH keys, names of the VPN clients.'
        printf '\n\n=== %s\n' "$(t 'Diagnostics')"
        (
            C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_DIM="" C_RESET=""
            INTERACTIVE=0
            OPT_LINK=0
            doctor_main
        ) 2>&1
        printf '\n=== %s\n' "$(t 'End of the log (last %s lines)' "$REPORT_LOG_LINES")"
        tail -n "$REPORT_LOG_LINES" "$APP_LOG" 2>/dev/null || true
    } >"$file"
    report_anonymize "$file"
}

# Makes the report, then a one-time link to it; without the site of a
# seedbox, saves it where the account that ran sudo can fetch it
report_send() {
    local tmp name owner home
    name="seedtunnel-report-$(date +%Y%m%d-%H%M%S).txt"
    tmp=$(mktemp)
    printf '%s\n' "$(t 'Preparing the report (the diagnostics run once more)…')"
    report_generate "$tmp"
    if report_by_link; then
        if ! (share_create "$tmp" "$name" "$(t 'seedtunnel report')" "$(text share_steps_report)" \
            "$(t 'Domain, name of the server, public IP addresses, SFTP account, SSH keys and names of the VPN clients are replaced. No password, no key.')"); then
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
        return 0
    fi
    owner=${SUDO_USER:-root}
    home=$(getent passwd "$owner" | cut -d: -f6 || true)
    [[ -d $home ]] || {
        owner=root
        home=/root
    }
    install -m 600 -o "$owner" "$tmp" "$home/$name"
    rm -f "$tmp"
    ok 'Report saved: %s' "$home/$name"
    say 'Without a seedbox there is no download link: fetch it with WinSCP, FileZilla or scp, logged in as %s.' "$owner"
}
