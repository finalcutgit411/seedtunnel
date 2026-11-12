#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
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
# left by Ubuntu and unattended-upgrades when a restart is needed; where the
# kernels are; the file that says when the server started
REBOOT_REQUIRED_FILE="/run/reboot-required"
BOOT_DIR="/boot"
PROC_STAT="/proc/stat"

doctor_ok() { ok "$@"; }

# A kernel installed since the server started, other than the one running.
# /run/reboot-required is left by Ubuntu and by unattended-upgrades, but not
# on a new Debian whose first « apt full-upgrade » ran before seedtunnel
# installed unattended-upgrades. The ctime of a kernel is when it was
# installed. A kernel not taken from /boot (given by the host, or in a
# container) is left alone: restarting would not change it.
kernel_installed_since_boot() {
    local boot file running
    boot=$(awk '$1 == "btime" { print $2 }' "$PROC_STAT" 2>/dev/null || true)
    [[ $boot =~ ^[0-9]+$ ]] || return 1
    running=$(uname -r)
    [[ -f $BOOT_DIR/vmlinuz-$running ]] || return 1
    for file in "$BOOT_DIR"/vmlinuz-*; do
        [[ -f $file && ${file#"$BOOT_DIR"/vmlinuz-} != "$running" ]] || continue
        if (($(stat -c %Z -- "$file") > boot)); then return 0; fi
    done
    return 1
}
doctor_warn() {
    DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
    printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t "$@")"
}
doctor_error() {
    DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1))
    printf '%s✘%s %s\n' "$C_RED" "$C_RESET" "$(t "$@")"
}
doctor_title() { printf '\n%s%s%s\n' "$C_BOLD" "$(t "$@")" "$C_RESET"; }

# doctor_service SERVICE "Name shown" [boot] — with « boot » (the services that
# « seedtunnel apply » enables), it must also start by itself at boot
doctor_service() {
    if systemctl is-active --quiet "$1"; then
        if [[ ${3-} == boot ]] && ! systemctl is-enabled --quiet "$1" 2>/dev/null; then
            doctor_warn '%s: running, but not started at boot: it will not come back after a restart of the server   → seedtunnel apply' "$2"
        else
            doctor_ok '%s: running' "$2"
        fi
    else
        doctor_error '%s: stopped   → journalctl -u %s -n 30' "$2" "$1"
    fi
}

# SSH started on demand by systemd (ssh.socket, Ubuntu): ssh.service only
# runs once someone has connected
doctor_ssh() {
    if ! systemctl is-active --quiet ssh.service && systemctl is-active --quiet ssh.socket; then
        doctor_ok 'SSH / SFTP: waiting for connections (ssh.socket)'
    else
        doctor_service ssh.service 'SSH / SFTP'
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
    doctor_restore_leftovers
    doctor_changed_by_hand
    if [[ -e $REBOOT_REQUIRED_FILE ]]; then
        doctor_warn 'Restart advised (update of the kernel or of a library)'
    elif kernel_installed_since_boot; then
        doctor_warn 'Restart advised: a kernel installed since the server started is not used yet   → reboot'
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
    doctor_service "wg-quick@$VPN_INTERFACE" 'WireGuard service' boot
    if [[ $(wg show "$VPN_INTERFACE" listen-port 2>/dev/null || true) == "$VPN_PORT" ]]; then
        doctor_ok 'Listening on port %s/udp' "$VPN_PORT"
    else
        doctor_error 'WireGuard is not listening on port %s/udp   → seedtunnel vpn restart' "$VPN_PORT"
    fi
    doctor_vpn_routing
    doctor_vpn_nat
    doctor_vpn_forward
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
# Files written by seedtunnel and changed by hand since: the next apply puts
# its version back (and keeps a copy of the other one)
doctor_changed_by_hand() {
    local list _sum file
    list=$(written_list)
    [[ -f $list ]] || return 0
    while read -r _sum file; do
        if written_changed "$file"; then
            doctor_warn '%s changed by hand: « seedtunnel apply » puts the version of seedtunnel back (and keeps a copy of yours)' "$file"
        fi
    done <"$list"
}

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

# The settings replaced by a finished restore stay in /etc with the old keys,
# password hashes and passphrase, until deleted (a restore cut short needs
# them: said above, not here)
doctor_restore_leftovers() {
    local -a kept
    restore_interrupted && return 0
    mapfile -t kept < <(restore_leftovers)
    ((${#kept[@]})) || return 0
    if ((${#kept[@]} == 1)); then
        doctor_warn 'Settings replaced by a restore still kept (old keys, passwords, passphrase). Once everything works:  rm -rf %s' "${kept[0]}"
    else
        doctor_warn 'Settings replaced by %s restores still kept (old keys, passwords, passphrase). Once everything works:  rm -rf %s' \
            "${#kept[@]}" "$APP_STATE_DIR.before-restore-*"
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

# Routing must be on for the server, and for the two interfaces the traffic of
# the clients crosses: the VPN and the way out to the Internet. (In the names
# of sysctl, the dot of an interface such as eth0.100 is written « / ».)
doctor_vpn_routing() {
    local dev key off=0
    if [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) != 1 ]]; then
        doctor_error 'IPv4 routing off: the clients will have no Internet   → seedtunnel apply'
        return 0
    fi
    for dev in "$VPN_INTERFACE" "$(default_interface)"; do
        [[ -n $dev ]] || continue
        key="net.ipv4.conf.${dev//./\/}.forwarding"
        if [[ $(sysctl -n "$key" 2>/dev/null) == 0 ]]; then
            doctor_error 'IPv4 routing off for %s: the clients will have no Internet   → sysctl -w %s=1' "$dev" "$key"
            off=1
        fi
    done
    if ((off == 0)); then doctor_ok 'IPv4 routing on'; fi
}

# Read by Docker when it starts. With « "ip-forward-no-drop": true », Docker
# no longer refuses by default the traffic that crosses the server.
DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
docker_forward_drop_off() { grep -Eqs '"ip-forward-no-drop"[[:space:]]*:[[:space:]]*true' "$DOCKER_DAEMON_CONFIG"; }

# forward_drop_tables INTERFACE <RULESET — the tables whose forward hook
# refuses by default (« policy drop »), one per line: « FAMILY NAME ALLOWED
# DOCKER ». ALLOWED is 1 when rules of the table accept what comes in by
# INTERFACE and what goes back to it (or any established connection); DOCKER
# is 1 for the table of Docker (it has a chain DOCKER-USER).
forward_drop_tables() {
    awk -v dev="\"$1\"" '
        /^table / { table = $2 " " $3; next }
        /^[ \t]*chain / { if ($2 == "DOCKER-USER") docker[table] = 1; next }
        /hook forward/ && /policy drop;/ { drop[table] = 1; next }
        !/[ \t]accept([ \t]|$)/ { next }
        index($0, "iifname " dev) { out[table] = 1 }
        index($0, "oifname " dev) { back[table] = 1 }
        /ct state [{ ]*(established, ?related|related, ?established)/ && !/(iif|oif)name/ { back[table] = 1 }
        END { for (t in drop) print t, ((out[t] && back[t]) ? 1 : 0), (docker[t] ? 1 : 0) }'
}

# The traffic of the clients crosses the server (forward hook). Another
# program, Docker most of all, may refuse it by default: the clients then
# connect, but nothing comes back from the Internet. A rule that refuses
# wins over any other table that accepts: it must be the program that set it
# that lets the VPN through.
doctor_vpn_forward() {
    local ruleset family name allowed docker interface blocked=0
    ruleset=$(nft list ruleset 2>/dev/null) || return 0
    interface=$(default_interface)
    while read -r family name allowed docker; do
        if ((allowed)) && { ((docker == 0)) || docker_forward_drop_off; }; then continue; fi
        blocked=1
        if ((allowed)); then
            doctor_warn 'Docker blocks the traffic that crosses the server; rules let the clients through for now, but those added by hand disappear at the next restart   → add  "ip-forward-no-drop": true  to %s' "$DOCKER_DAEMON_CONFIG"
        elif ((docker)); then
            doctor_error 'Docker blocks the traffic of the clients: they connect, but have no Internet'
            say '  Right now (until the next restart):'
            printf '    iptables -I DOCKER-USER -i %s -o %s -j ACCEPT\n' "$VPN_INTERFACE" "${interface:-?}"
            printf '    iptables -I DOCKER-USER -i %s -o %s -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT\n' "${interface:-?}" "$VPN_INTERFACE"
            if docker_forward_drop_off; then
                say '  Already in %s: Docker no longer blocks after the next restart of the server.' "$DOCKER_DAEMON_CONFIG"
            else
                say '  For good: add  "ip-forward-no-drop": true  to %s (read when Docker starts)' "$DOCKER_DAEMON_CONFIG"
            fi
        else
            doctor_error 'The firewall rules of another program (table %s) block the traffic of the clients: they connect, but have no Internet. They must accept what comes in by %s and what goes back to it.' "$family $name" "$VPN_INTERFACE"
        fi
    done < <(forward_drop_tables "$VPN_INTERFACE" <<<"$ruleset")
    if ((blocked == 0)); then doctor_ok 'Traffic of the clients to the Internet: allowed'; fi
}

# Ubuntu 26.04: AppArmor must let Transmission into the data folder. The rules
# in place, and no refusal since they were written (refused, it cannot
# download, whatever the permissions of the folder).
doctor_transmission_apparmor() {
    local since refused
    transmission_apparmor_confined || return 0
    if [[ $(transmission_apparmor_generate) != "$(cat "$TRANSMISSION_APPARMOR_LOCAL" 2>/dev/null)" ]]; then
        doctor_error 'AppArmor keeps Transmission out of %s: downloads fail   → seedtunnel apply' "$SEEDBOX_DATA_DIR"
        return 0
    fi
    since=$(stat -c %Y "$TRANSMISSION_APPARMOR_LOCAL" 2>/dev/null || echo 0)
    refused=$(journalctl -k -b --since "@$since" --no-pager 2>/dev/null | grep -c 'apparmor="DENIED".*profile="transmission-daemon"' || true)
    if ((refused > 0)); then
        doctor_error 'AppArmor refused Transmission %s time(s) since its rules were written   → journalctl -k -b | grep transmission-daemon' "$refused"
    else
        doctor_ok 'AppArmor lets Transmission write to %s' "$SEEDBOX_DATA_DIR"
    fi
}

# The .torrent files of watch/ that Transmission cannot read are never added:
# only « Permission denied » again and again in its journal (a file copied
# there by root keeps the rights of its original, 600). Said, not changed:
# root does not touch by itself the files of a folder where the SFTP user
# writes (a file there can be swapped for a link to another one), and does not
# advise a command that would (chmod and chgrp follow links): adding them again
# through the web interface or by SFTP gives them the right owner.
doctor_watch_unreadable() {
    local watch="$SEEDBOX_DATA_DIR/watch" file mode owner group count=0
    for file in "$watch"/*.torrent; do
        [[ -f $file && ! -L $file ]] || continue
        read -r mode owner group < <(stat -c '%a %U %G' "$file" 2>/dev/null) || continue
        mode=000$mode
        mode=${mode: -3}
        # readable by others, by the group of Transmission, or by Transmission itself
        if ((${mode:2:1} & 4)) || { [[ $group == "$TRANSMISSION_USER" ]] && ((${mode:1:1} & 4)); } \
            || { [[ $owner == "$TRANSMISSION_USER" ]] && ((${mode:0:1} & 4)); }; then
            continue
        fi
        count=$((count + 1))
    done
    if ((count > 0)); then
        doctor_warn '%s .torrent file(s) of %s unreadable by Transmission, never added   → add them again through the web interface or by SFTP' \
            "$count" "$watch/"
    fi
}

# Transmission, or why the full disk protection keeps it stopped
doctor_transmission() {
    local free
    if ! diskguard_stopped; then
        doctor_service transmission-daemon 'Transmission' boot
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

# doctor_name_certificate IP — the name of the seedbox and its certificate.
# With an IP address, one warning, and what changes it: a domain name (the
# same IP again would give the same certificate).
doctor_name_certificate() {
    local ip=$1 crt days
    if is_ipv4 "$SEEDBOX_DOMAIN"; then
        doctor_warn 'No domain name: access by IP, self-signed certificate (browser warning)   → with a domain name pointing to this server:  seedtunnel seedbox domain NAME'
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
        if ! is_ipv4 "$SEEDBOX_DOMAIN"; then
            doctor_warn 'Self-signed certificate (browser warning)   → seedtunnel seedbox domain %s' "$SEEDBOX_DOMAIN"
        fi
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
}

doctor_seedbox() {
    local ip=$1 code free settings
    doctor_title 'Seedbox'
    doctor_transmission
    doctor_service nginx 'nginx' boot
    doctor_service fail2ban 'fail2ban' boot
    doctor_ssh
    if systemctl is-active --quiet seedtunnel-diskguard.timer; then
        doctor_ok 'Full disk protection on (Transmission stopped under %s GB free)' "$DISKGUARD_STOP_BELOW_GB"
    else
        doctor_warn 'Full disk protection off   → seedtunnel apply'
    fi

    doctor_name_certificate "$ip"

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
    doctor_sftp_password
    doctor_torrent_port
    if seedbox_check_data_dir "$SEEDBOX_DATA_DIR" 2>/dev/null; then
        doctor_ok 'Permissions of the data folder correct'
    else
        doctor_error 'Permissions of the folder %s incompatible with the locked SFTP' "$SEEDBOX_DATA_DIR"
    fi
    doctor_transmission_apparmor
    doctor_watch_unreadable
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

# The password of SFTP, allowed by default (needed before the first SSH key):
# a warning only once there is a key, the password then being of no use
doctor_sftp_password() {
    if [[ $SEEDBOX_SFTP_PASSWORD != yes ]]; then
        doctor_ok 'SFTP: SSH keys only (password refused)'
    elif (($(sftp_keys_count) > 0)); then
        doctor_warn 'SFTP: the password is still allowed, though you have an SSH key: refuse it   → seedtunnel seedbox sftp-password off'
    else
        printf '  %s\n' "$(t '(SFTP: password allowed; an SSH key is safer: menu Seedbox › SSH keys for SFTP)')"
    fi
}

# Is the BitTorrent port reachable from the Internet? Asked to the service of
# Transmission for its own port test (IPv4 only): it connects back to the
# server, and answers 1 (open) or 0 (closed). Without an answer: not tested,
# no warning.
doctor_torrent_port() {
    local answer
    systemctl is-active --quiet transmission-daemon 2>/dev/null || return 0
    answer=$(curl -4 -fsS --max-time 20 "https://portcheck.transmissionbt.com/$TORRENT_PORT" 2>/dev/null || true)
    case $answer in
        1*) doctor_ok 'BitTorrent port %s open from the Internet' "$TORRENT_PORT" ;;
        0*) doctor_warn 'BitTorrent port %s closed from the Internet: check the firewall of the hosting provider (at OVH: « Edge Network Firewall », in the control panel)' "$TORRENT_PORT" ;;
        *) printf '  %s\n' "$(t '(BitTorrent port %s not tested: the test service of Transmission did not answer)' "$TORRENT_PORT")" ;;
    esac
}

doctor_firewall() {
    local rules port open
    doctor_title 'Firewall'
    if { vpn_installed || seedbox_installed; } && ufw_active; then
        doctor_error 'ufw (the firewall of Ubuntu) is on: it blocks the VPN and the seedbox   → sudo ufw disable, then seedtunnel firewall enable'
    fi
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
    section 'Diagnostics'
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
REPORT_COMMON_WORDS=" backup client clients debian firewall localhost nginx root seedbox seedtunnel server sftp ssh transmission ubuntu vpn vps web wg0 "
REPORT_SCRIPT=""

report_common_word() { [[ $REPORT_COMMON_WORDS == *" ${1,,} "* ]]; }

# One known private value, as « length<TAB>value<TAB>replacement »: they are
# replaced longest first (the client « lancelot-laptop » before the account « lancelot »)
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
    done < <(grep -oiE '((download link for|lien de téléchargement pour) |clients/)[A-Za-z0-9_-]+\.(conf|env)' "$file" \
        | sed -E 's/^([Dd]ownload link for |[Ll]ien de téléchargement pour |clients\/)//; s/\.(conf|env)$//' | sort -u || true)
    # domains used before (the domain changed since), as the log names them:
    # title of the certificate, self-signed certificate (CN=, DNS:)
    while IFS= read -r name; do
        if [[ $name != "${SEEDBOX_DOMAIN-}" && $name != "${VPN_PUBLIC_ADDRESS-}" ]] && ! report_common_word "$name"; then
            report_known "$name" "$(t '<former-domain>')"
        fi
    done < <(grep -oiE "((let's encrypt certificate for|certificat let's encrypt pour) |CN=|DNS:)[a-z0-9.-]+\.[a-z]{2,63}" "$file" \
        | sed -E "s/^(.* (for|pour) |CN=|DNS:)//I" | sort -u || true)
    # SFTP accounts used before (renamed, removed): titles of the log, useradd
    while IFS= read -r name; do
        if [[ $name != "${SEEDBOX_USER-}" ]] && ! report_common_word "$name"; then
            report_known "$name" "$(t '<former-sftp-user>')"
        fi
    done < <(sed -nE "s/.*(Creating the user|Deleting the user|Création de l'utilisateur|Suppression de l'utilisateur) ([a-z_][a-z0-9_-]*).*/\2/p; s/^\\\$ useradd .* ([a-z_][a-z0-9_-]*)$/\1/p" "$file" | sort -u || true)
    # the accounts of the administrators: the one that ran sudo, those logged
    # in. Not the SFTP account: « who » can list it too while WinSCP is
    # connected (Debian 13 counts the SFTP sessions), and it has its own name
    while IFS= read -r name; do
        if [[ $name =~ ^[a-z_][a-z0-9_.-]*$ && $name != "${SEEDBOX_USER-}" ]] && ! report_common_word "$name"; then
            report_known "$name" "$(t '<admin>')"
        fi
    done < <({
        printf '%s\n' "${SUDO_USER-}"
        who 2>/dev/null | awk '{ print $1 }'
    } | sort -u || true)
}

# The addresses of the DNS services offered in the menu, one per line
report_dns_addresses() {
    local key
    for key in "${VPN_DNS_SERVICES[@]}"; do
        vpn_dns_value "$key" | tr -s ', ' '\n'
        echo
    done
}

# Replaces what is private in FILE
report_anonymize() {
    local file=$1 _length value replacement address dns
    # colors first, then the known values, longest first (the name of the
    # server is often part of a domain, an account part of a client name)
    REPORT_SCRIPT='s/\x1b\[[0-9;]*m//g;'
    while IFS=$'\t' read -r _length value replacement; do
        report_replace "$value" "$replacement"
    done < <(report_known_values "$file" | sort -t $'\t' -k1,1nr)
    # SSH public keys with their comment, and fingerprints
    REPORT_SCRIPT+='s/(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+\/=]+( [^ ]+)?/'"$(t '<ssh-key>')"'/g;'
    REPORT_SCRIPT+='s/SHA256:[A-Za-z0-9+\/]{43}/'"$(t '<fingerprint>')"'/g;'
    # the accounts named by needrestart (« jean @ session #1: sshd… », « jean @
    # user manager service: systemd… », « jean @ user manager: (sd-pam)… » on
    # Ubuntu 26.04), and the names of the backups made by another server
    REPORT_SCRIPT+='s/^( *)[a-z_][a-z0-9_.-]* @ (session #|user manager)/\1'"$(t '<admin>')"' @ \2/;'
    REPORT_SCRIPT+='s/seedtunnel-[A-Za-z0-9._-]+-([0-9]{8}-[0-9]{6})/seedtunnel-'"$(t '<server>')"'-\1/g;'
    sed -E -i "$REPORT_SCRIPT" "$file"
    # the other public addresses, as found in what is left; not those of the
    # DNS services of the menu (Quad9…): the same for everyone, they say which
    # one is used (one typed by hand is replaced)
    REPORT_SCRIPT=""
    dns=$(report_dns_addresses)
    while IFS= read -r address; do
        if grep -qxF -- "$address" <<<"$dns"; then continue; fi
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
        t 'Replaced: domains, names of the server, public IP addresses, SFTP accounts, administrators, SSH keys, names of the VPN clients.'
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
