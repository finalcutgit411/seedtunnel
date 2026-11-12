#!/usr/bin/env bash
# =============================================================================
#  Integration tests of seedtunnel
#
#  Run by GitHub Actions in a fresh Debian container with systemd (see
#  .github/workflows/ci.yml and tests/Dockerfile). They really install
#  everything, check that every service answers, then remove it all.
#
#  NEVER RUN THIS ON A REAL SERVER: everything would be installed then removed.
#
#  Usage: integration.sh phase1   installation, VPN, seedbox, SFTP, firewall
#         integration.sh phase2   diagnostics, backups, restore, removal
# =============================================================================
set -Euo pipefail

APP=/opt/seedtunnel/seedtunnel.sh
W=/root/seedtunnel-tests
SBU=lancelot
PW1="password-ci-123"
PW2="new-password-ci-456"
DATA=/srv/seedbox
PASS=0
FAIL=0

[[ -f /.dockerenv || ${CI-} == true ]] || {
    echo "Refused: these tests must only run in the test container." >&2
    exit 1
}

step() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }

# On GitHub Actions, every failure also becomes an annotation: it shows in the
# summary of the run, with the end of the output of the command.
annotate() {
    local title body
    title="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME") — $1"
    title=${title//'%'/'%25'}
    title=${title//:/%3A}
    title=${title//,/%2C}
    body=$(tail -n 25 "$W/check.out")
    body=${body//'%'/'%25'}
    body=${body//$'\r'/'%0D'}
    body=${body//$'\n'/'%0A'}
    printf '::error title=%s::%s\n' "$title" "$body"
}

# check "description" command…  → the command must succeed
check() {
    local description=$1
    shift
    if "$@" >"$W/check.out" 2>&1; then
        printf '  \033[32m✔\033[0m %s\n' "$description"
        PASS=$((PASS + 1))
    else
        printf '  \033[31m✘ %s\033[0m\n' "$description"
        tail -n 25 "$W/check.out" | sed 's/^/      /'
        annotate "$description"
        FAIL=$((FAIL + 1))
    fi
}

# check_fails "description" command…  → the command must fail
check_fails() {
    local description=$1
    shift
    if "$@" >"$W/check.out" 2>&1; then
        printf '  \033[31m✘ %s (succeeded but should have failed)\033[0m\n' "$description"
        tail -n 25 "$W/check.out" | sed 's/^/      /'
        annotate "$description (should have failed)"
        FAIL=$((FAIL + 1))
    else
        printf '  \033[32m✔\033[0m %s\n' "$description"
        PASS=$((PASS + 1))
    fi
}

# seedtunnel without a terminal, as in a script, with the reduced PATH you get
# after a « su » without a dash (no /usr/sbin): the script must cope alone
app() { env PATH=/usr/local/bin:/usr/bin:/bin "$APP" "$@" </dev/null; }

# Does the output of a command contain a text? (output captured first: a
# « cmd | grep -q » can fail wrongly with pipefail)
output_has() {
    local text=$1 out
    shift
    out=$("$@" 2>&1) || true
    grep -qF -- "$text" <<<"$out"
}

# A new DNS is written in the file of each client; the same again changes nothing
vpn_dns_test() {
    app vpn dns cloudflare >/dev/null || return 1
    grep -qx "DNS = 1.1.1.1, 1.0.0.1" /etc/seedtunnel/vpn/clients/phone.conf || return 1
    output_has "Nothing to change" app vpn dns cloudflare || return 1
    app vpn dns quad9 >/dev/null || return 1
    grep -qx "DNS = 9.9.9.9, 149.112.112.112" /etc/seedtunnel/vpn/clients/phone.conf
}

# The QR code of a client fits in a window of 80 columns (89 with the comments
# of the file: its lines wrapped and no phone could read it); its file keeps
# its comments
vpn_qr_test() {
    local out line widest=0 LC_ALL
    out=$(app vpn show phone 2>&1) || return 1
    # characters counted, not bytes
    LC_ALL=C.UTF-8
    while IFS= read -r line; do
        [[ $line == *█* ]] || continue
        line=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$line")
        ((${#line} > widest)) && widest=${#line}
    done <<<"$out"
    echo "widest line of the QR code: $widest columns"
    ((widest > 0 && widest <= 80)) || return 1
    grep -q '^# seedtunnel — client "phone"' /etc/seedtunnel/vpn/clients/phone.conf
}

# Installed with an IP address: one warning, that asks for a domain name (not
# the same IP again); « (fallback) » not in the title of its certificate
doctor_ip_test() {
    local out
    out=$(app doctor 2>&1) || true
    grep -qF "seedtunnel seedbox domain NAME" <<<"$out" || return 1
    ! grep -qF "seedbox domain 127.0.0.1" <<<"$out" || return 1
    grep -q "· Creating a self-signed certificate$" /var/log/seedtunnel.log
}

# The NAT rules of the VPN follow wg0: removed when it stops, loaded again by
# systemd when it starts (not by wg-quick, which AppArmor confines on Ubuntu 26.04)
vpn_nat_follows_wg0() {
    systemctl stop wg-quick@wg0 || return 1
    if nft list table ip seedtunnel &>/dev/null; then
        echo "NAT table still there after the stop"
        return 1
    fi
    systemctl start wg-quick@wg0 || return 1
    nft list table ip seedtunnel | grep -q masquerade
}

# HTTP code returned by the seedbox (credentials optional)
http_code() {
    local path=$1
    shift
    curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@" "https://127.0.0.1$path"
}
http_is() {
    local want=$1
    shift
    [[ $(http_code "$@") == "$want" ]]
}

# SFTP commands with a password or with a key
sftp_password() {
    printf '%s\n' "$2" | sshpass -p "$1" sftp -q -oBatchMode=no -oStrictHostKeyChecking=no \
        -oUserKnownHostsFile=/dev/null -oPubkeyAuthentication=no -b - "$SBU@127.0.0.1"
}
# The SFTP account renamed, then back to its name: it works under its new
# name, and is never left suspended
rename_test() {
    local new=st-renamed
    printf '%s\n' "$PW2" | env PATH=/usr/local/bin:/usr/bin:/bin "$APP" seedbox password --user "$new" || return 1
    id "$new" &>/dev/null && ! id "$SBU" &>/dev/null || return 1
    [[ -z $(getent shadow "$new" | cut -d: -f8) ]] || return 1
    http_is 409 /transmission/rpc -u "$new:$PW2" || return 1
    printf 'ls\n' | sshpass -p "$PW2" sftp -q -oBatchMode=no -oStrictHostKeyChecking=no \
        -oUserKnownHostsFile=/dev/null -oPubkeyAuthentication=no -b - "$new@127.0.0.1" >"$W/rename.out" || return 1
    grep -q watch "$W/rename.out" || return 1
    printf '%s\n' "$PW2" | env PATH=/usr/local/bin:/usr/bin:/bin "$APP" seedbox password --user "$SBU" || return 1
    id "$SBU" &>/dev/null && ! id "$new" &>/dev/null && [[ -z $(getent shadow "$SBU" | cut -d: -f8) ]]
}
# Runs one function of seedtunnel, its libraries and settings loaded (for a
# check that the commands only use in a terminal)
seedtunnel_function() {
    bash -c '
        APP_DIR=/opt/seedtunnel
        for library in common i18n ui vpn seedbox firewall share diskguard backup update doctor menu; do
            . "$APP_DIR/lib/$library.sh"
        done
        i18n_load en
        vpn_load
        seedbox_load
        "$@"' seedtunnel "$@"
}

# The system of the test server: accepted, and named in the header as « Ubuntu 24.04 »
system_named() {
    local want got
    want=$(. /etc/os-release && printf '%s %s' "${NAME%% *}" "$VERSION_ID")
    got=$(seedtunnel_function eval 'os_check && ui_server_names && printf "%s" "$UI_SYSTEM"') || return 1
    echo "header: $got, expected: $want"
    [[ $got == "$want" ]]
}

# Confirming the firewall: a real SSH login, from the client network, is
# recognised (Debian 12 and 13: the program writing it is the right one), a
# fake message written by another program calling itself sshd is not
firewall_proof_test() {
    local start i
    start=$(date +%s)
    sleep 1
    logger -t sshd "Accepted publickey for admin from 203.0.113.9 port 50000 ssh2: ED25519 SHA256:fake"
    sleep 1
    if seedtunnel_function firewall_new_ssh_login "$start"; then
        echo "fake message accepted as a proof"
        return 1
    fi
    useradd -m st-admin
    printf 'st-admin:%s\n' "$PW1" | chpasswd
    ip netns exec st-client sshpass -p "$PW1" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null \
        -oPubkeyAuthentication=no st-admin@192.168.250.1 true || {
        userdel -r st-admin 2>/dev/null
        return 1
    }
    userdel -r st-admin 2>/dev/null || true
    for i in 1 2 3 4 5; do
        if seedtunnel_function firewall_new_ssh_login "$start"; then return 0; fi
        sleep 1
    done
    echo "real SSH login not recognised; what the journal holds:"
    journalctl --since "@$start" -o verbose --no-pager | grep -E 'MESSAGE=Accepted|_EXE=|_COMM=' | tail -n 12
    return 1
}

sftp_key() {
    printf '%s\n' "$1" | sftp -q -i "$W/key" -oIdentitiesOnly=yes -oBatchMode=yes \
        -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -b - "$SBU@127.0.0.1"
}

# Real WireGuard tunnel: a « client » in a separate network namespace connects
# with the configuration generated for « phone » and pings the server.
tunnel_test() {
    local conf=/etc/seedtunnel/vpn/clients/phone.conf private psk public
    private=$(awk -F' = ' '/^PrivateKey/ { print $2 }' "$conf")
    psk=$(awk -F' = ' '/^PresharedKey/ { print $2 }' "$conf")
    public=$(awk -F' = ' '/^PublicKey/ { print $2 }' "$conf")
    ip netns del st-client 2>/dev/null || true
    ip link del st-veth0 2>/dev/null || true
    ip netns add st-client
    ip link add st-veth0 type veth peer name st-veth1
    ip link set st-veth1 netns st-client
    ip addr add 192.168.250.1/24 dev st-veth0
    ip link set st-veth0 up
    ip -n st-client addr add 192.168.250.2/24 dev st-veth1
    ip -n st-client link set st-veth1 up
    ip -n st-client link set lo up
    ip -n st-client link add wgc type wireguard
    ip netns exec st-client wg set wgc private-key <(printf '%s\n' "$private") \
        peer "$public" preshared-key <(printf '%s\n' "$psk") \
        endpoint 192.168.250.1:51820 allowed-ips 10.8.0.0/24
    ip -n st-client addr add 10.8.0.2/32 dev wgc
    ip -n st-client link set wgc up
    ip -n st-client route add 10.8.0.0/24 dev wgc
    ip netns exec st-client ping -c 3 -W 2 10.8.0.1
}

# The command succeeds without any « starting / applying… » line: nothing was
# touched
nothing_changed() {
    local out
    out=$("$@" 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    ! grep -E 'Starting|Restarting|Reloading|Stopping|Applying|Installing|Creating|Enabling|Updating' <<<"$out"
}

# « seedtunnel firewall rules » reads the rules nftables really has: every
# part in words, the port of the client, nothing unknown nor missing
firewall_rules_test() {
    local out expected
    out=$(app firewall rules 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    printf '%s\n' "$out"
    for expected in "Replies to the connections already open" "Ping and ICMP messages" "SSH / SFTP: port 22/tcp" \
        "VPN WireGuard: port 51820/udp" "Everything coming from the VPN clients" "Web site: ports 80, 443/tcp" \
        "BitTorrent: port 60000 (TCP and UDP)" "Everything else is refused." "port 60001 (TCP and UDP) → phone (10.8.0.2)"; do
        [[ $out == *"$expected"* ]] || {
            echo "missing: $expected"
            return 1
        }
    done
    [[ $out != *"Other rule"* && $out != *"Other port open"* && $out != *"Missing from"* ]]
}

# « seedtunnel doctor --link »: the report downloaded by its link holds none
# of the private values of this server, no password, no key
report_link_test() {
    local out path page name value
    out=$(app doctor --link 2>&1) || true
    path=$(share_path "$out") || {
        printf 'no link:\n%s\n' "$out"
        return 1
    }
    page=$(curl -sk --max-time 10 "https://127.0.0.1$path")
    name=$(grep -oE 'seedtunnel-report-[0-9-]+\.txt' <<<"$page" | head -n 1)
    [[ -n $name ]] || return 1
    curl -skf --max-time 10 -o "$W/report.txt" "https://127.0.0.1${path}$name" || return 1
    grep -q "=== Diagnostics" "$W/report.txt" && grep -q "End of the log" "$W/report.txt" || return 1
    for value in "$SBU" phone laptop "$(hostname)"; do
        if grep -qw -- "$value" "$W/report.txt"; then
            echo "still in the report: $value"
            grep -nw -- "$value" "$W/report.txt" | head -5
            return 1
        fi
    done
    for value in "$PW1" "$PW2" "PrivateKey" "PRIVATE KEY" "$(awk '{ print $2 }' "$W/key.pub")"; do
        if grep -qF -- "$value" "$W/report.txt"; then
            echo "a secret is in the report"
            return 1
        fi
    done
    link_gone "${path}$name"
}

# A backup made when the server had its VPN only, restored now that it also
# has a seedbox: refused before anything is replaced
restore_missing_part_test() {
    output_has "This server has a seedbox, the backup has none" \
        app restore "$W/vpn-only.enc" --passphrase-file "$W/vpn-only.pass" --yes || return 1
    test -s /etc/seedtunnel/seedbox.conf && id "$SBU" >/dev/null && test -e /etc/ssh/sshd_config.d/seedtunnel-seedbox.conf \
        && ! test -e /etc/seedtunnel.restore-unfinished
}

# The first backup of phase 2 was made by hand, before the weekly backup was
# turned on: it holds no passphrase for it
restore_older_backup_test() {
    local older="" file
    # the oldest backup made by hand
    for file in /var/backups/seedtunnel/*.tar.gz.enc; do
        [[ $file != *-auto.tar.gz.enc ]] || continue
        if [[ -z $older || $file -ot $older ]]; then older=$file; fi
    done
    [[ -n $older ]] || return 1
    output_has "is kept, with its passphrase" app restore "$older" --passphrase-file "$W/passphrase" --yes || return 1
    test -s /etc/seedtunnel/backup.passphrase && systemctl is-enabled --quiet seedtunnel-backup.timer \
        && app backup auto run
}

# A torrent added by a magnet link, without its metadata yet, is only its link
# for Transmission 4 (HASH.magnet in its list). Put in a backup, it comes back
# through watch/ with Transmission 4; with Transmission 3 (Debian 12), it is
# saved in a file, to add again by hand
MAGNET_HASH=5eed7a11e15f0000000000000000000000000001
restore_magnet_test() {
    local dir="$W/magnet" state="var/lib/transmission-daemon/.config/transmission-daemon" member names
    local link="magnet:?xt=urn:btih:$MAGNET_HASH&dn=seedtunnel-magnet-test"
    local -a members=()
    rm -rf "$dir"
    mkdir -p "$dir/x"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass file:"$W/passphrase" -in "$W/backup.enc" \
        | tar -xzf - -C "$dir/x" || return 1
    mkdir -p "$dir/x/$state/torrents"
    printf '%s' "$link" >"$dir/x/$state/torrents/$MAGNET_HASH.magnet"
    # the same members as a real backup (no parent folder of its own)
    for member in etc/seedtunnel etc/letsencrypt etc/ssh/seedtunnel_authorized_keys "$state/torrents" "$state/resume" \
        "$state/settings.json" etc/transmission-daemon/settings.json; do
        if [[ -e $dir/x/$member ]]; then members+=("$member"); fi
    done
    tar -czf - -C "$dir/x" "${members[@]}" \
        | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass file:"$W/passphrase" -out "$dir/magnet.enc" || return 1
    app restore "$dir/magnet.enc" --passphrase-file "$W/passphrase" --yes >"$dir/out" 2>&1 || {
        cat "$dir/out"
        return 1
    }
    cat "$dir/out"
    if dpkg --compare-versions "$(dpkg-query -W -f='${Version}' transmission-daemon)" ge 4.0.0~; then
        wait_torrents 2 || return 1
        names=$(torrent_names)
        echo "$names"
        grep -qx seedtunnel-magnet-test <<<"$names"
    else
        grep -q "Magnet links to add again by hand" "$dir/out" && grep -qxF "$link" /root/seedtunnel-magnets.txt \
            && wait_torrents 1
    fi
}

# Names of the torrents in Transmission, through nginx and its RPC
torrent_names() {
    local session
    session=$(curl -sk -u "$SBU:$PW2" -D - -o /dev/null https://127.0.0.1/transmission/rpc \
        | awk -F': ' 'tolower($1) == "x-transmission-session-id" { print $2 }' | tr -d '\r')
    curl -sk -u "$SBU:$PW2" -H "X-Transmission-Session-Id: $session" \
        -d '{"method":"torrent-get","arguments":{"fields":["name"]}}' https://127.0.0.1/transmission/rpc \
        | jq -r '.arguments.torrents[].name'
}

# The settings replaced by the restores above are said by the diagnostics,
# with the command to delete them; once deleted, no longer said
restore_leftovers_test() {
    output_has "still kept (old keys, passwords, passphrase)" app doctor || return 1
    rm -rf /etc/seedtunnel.before-restore-*
    ! output_has "still kept" app doctor
}

# The full disk protection turned off by hand (disabled and stopped): the
# next « seedtunnel apply » enables and starts it again, then changes nothing
timers_put_back_test() {
    systemctl disable --now seedtunnel-diskguard.timer || return 1
    output_has "Enabling the full disk protection" app apply || return 1
    systemctl is-enabled --quiet seedtunnel-diskguard.timer && systemctl is-active --quiet seedtunnel-diskguard.timer \
        && nothing_changed app apply
}

# An unknown command, or a command with arguments too many, stops before the
# lock is taken: it works even while another seedtunnel holds it
commands_refused_first_test() {
    local rc=0
    (
        exec 9<>/run/seedtunnel.lock
        flock 9
        sleep 5
    ) &
    sleep 1
    output_has "Unknown command" app whatever && output_has "Too many arguments" app apply now || rc=1
    wait
    return "$rc"
}

# Kernel network hardening applied, including on the existing interface
net_hardened() {
    local interface
    interface=$(ip -4 route show default | awk '{ print $5; exit }')
    sysctl net.ipv4.conf.all.send_redirects net.ipv4.conf.all.accept_source_route "net.ipv4.conf.$interface.accept_redirects"
    [[ $(sysctl -n net.ipv4.conf.all.send_redirects net.ipv4.conf.all.accept_source_route \
        "net.ipv4.conf.$interface.accept_redirects" | tr -d '\n') == 000 ]]
}

# « /share/<token>/ » path of the link printed by a command
share_path() {
    local url
    url=$(grep -oE 'https://[^ ]+/share/[0-9a-f]{32}/' <<<"$1" | head -n 1)
    [[ -n $url ]] || return 1
    printf '/%s' "${url#https://*/}"
}

# Gone means 404 (the watcher deletes the link right after the opening)
link_gone() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ $(http_code "$1") == 404 ]] && return 0
        sleep 1
    done
    echo "still downloadable: $1"
    return 1
}

# One-time link: the page opens (several times), the file downloads once,
# then the link is gone
share_test() {
    local out path page
    out=$(app vpn share phone 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    path=$(share_path "$out") || {
        printf 'no link:\n%s\n' "$out"
        return 1
    }
    page=$(curl -sk --max-time 10 "https://127.0.0.1$path")
    [[ $page == *"Download phone.conf"* ]] || {
        printf 'unexpected page:\n%s\n' "$page"
        return 1
    }
    [[ $(http_code "$path") == 200 ]] || {
        echo "opening the page must not use up the link"
        return 1
    }
    curl -skf --max-time 10 -o "$W/shared.conf" "https://127.0.0.1${path}phone.conf" || return 1
    cmp "$W/shared.conf" /etc/seedtunnel/vpn/clients/phone.conf || return 1
    link_gone "${path}phone.conf"
}

# The tokens of the links never reach the access log of nginx: /share/<token>/
# instead, with the address, the time and the result
share_log_test() {
    local out path token
    out=$(app vpn share phone 2>&1) || return 1
    path=$(share_path "$out") || return 1
    token=${path#/share/}
    token=${token%/}
    curl -sk --max-time 10 -o /dev/null "https://127.0.0.1$path" || return 1
    curl -skf --max-time 10 -o /dev/null "https://127.0.0.1${path}phone.conf" || return 1
    curl -s --max-time 10 -o /dev/null "http://127.0.0.1${path}phone.conf" || true
    sleep 1
    if grep -qF "$token" /var/log/nginx/access.log; then
        echo "token found in the access log"
        return 1
    fi
    grep -qF '"GET /share/<token>/phone.conf HTTP' /var/log/nginx/access.log
}

# Another form of the address (here with « ?x ») does not get around the
# single use: the first download, whatever its address, uses up the link
share_variant_test() {
    local out path
    out=$(app vpn share phone 2>&1) || return 1
    path=$(share_path "$out") || return 1
    curl -skf --max-time 10 -o "$W/shared2.conf" "https://127.0.0.1${path}phone.conf?x=1" || return 1
    cmp "$W/shared2.conf" /etc/seedtunnel/vpn/clients/phone.conf || return 1
    link_gone "${path}phone.conf"
}

# No partial download: a Range request gets the whole file (200, not 206)
share_no_range_test() {
    local out path code size
    out=$(app vpn share phone 2>&1) || return 1
    path=$(share_path "$out") || return 1
    code=$(curl -sk --max-time 10 -r 0-9 -o "$W/shared3.conf" -w '%{http_code}' "https://127.0.0.1${path}phone.conf")
    size=$(stat -c %s "$W/shared3.conf")
    [[ $code == 200 && $size == "$(stat -c %s /etc/seedtunnel/vpn/clients/phone.conf)" ]] || {
        echo "code $code, $size bytes"
        return 1
    }
}

# Two requests one right after the other, on the same connection: only the
# first one gets the file (nginx refuses the second one on the spot, without
# waiting for the watcher to delete the file)
share_same_connection_test() {
    local out path codes
    out=$(app vpn share phone 2>&1) || return 1
    path=$(share_path "$out") || return 1
    codes=$(curl -sk --max-time 10 -w '%{http_code} %{num_connects}\n' \
        -o "$W/first.conf" "https://127.0.0.1${path}phone.conf" \
        -o "$W/second.conf" "https://127.0.0.1${path}phone.conf")
    [[ $codes == $'200 1\n404 0' ]] || {
        printf 'HTTP code and new connections, for each request:\n%s\n' "$codes"
        return 1
    }
    cmp "$W/first.conf" /etc/seedtunnel/vpn/clients/phone.conf
}

# The watcher of a link dies (crash, killed): the link is deleted anyway (its
# folder, not only « 404 »: nginx refuses a second download within a minute
# anyway). Its token, the password of the link, is in no command line.
share_watcher_killed_test() {
    local out path token job unit i
    out=$(app vpn share phone 2>&1) || return 1
    path=$(share_path "$out") || return 1
    token=$(cut -d/ -f3 <<<"$path")
    ps -eo args >"$W/ps.txt"
    systemctl status --no-pager 'seedtunnel-share-*' >>"$W/ps.txt" 2>&1 || true
    if grep -qF -- "$token" "$W/ps.txt"; then
        echo "the token of the link is in a command line"
        return 1
    fi
    job=$(grep -lF -- "$token" /run/seedtunnel-share.jobs/* 2>/dev/null | grep -v '\.stop$' | head -n 1)
    [[ -n $job ]] || return 1
    unit="seedtunnel-share-${job##*/}"
    systemctl show -p ExecStopPost -p ExecStopPostEx "$unit" >"$W/stop-post.txt" 2>&1 || true
    systemctl kill --signal=KILL "$unit" || return 1
    # by ExecStopPost (not always run by a recent systemd after a kill), or
    # at the latest by the timer of the end of the link (started here at once)
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [[ ! -e /run/seedtunnel-share/$token && ! -e $job && ! -e $job.stop ]]; then
            [[ $(http_code "${path}phone.conf") == 404 ]] && return 0
        fi
        if ((i == 5)); then systemctl start "$unit-end.service" 2>&1 || true; fi
        sleep 1
    done
    echo "link or job left behind after the watcher was killed:"
    ls -la /run/seedtunnel-share /run/seedtunnel-share.jobs 2>&1 | sed 's/^/  /'
    sed 's/^/  /' "$W/stop-post.txt"
    systemctl status --no-pager "$unit" 2>&1 | sed 's/^/  /' || true
    return 1
}

# HEAD is refused without using the link up: the download that follows works
share_head_test() {
    local out path code
    out=$(app vpn share phone 2>&1) || return 1
    path=$(share_path "$out") || return 1
    code=$(curl -sk --max-time 10 -I -o /dev/null -w '%{http_code}' "https://127.0.0.1${path}phone.conf")
    [[ $code == 405 ]] || {
        echo "HEAD: $code instead of 405"
        return 1
    }
    sleep 1
    code=$(curl -sk --max-time 10 -o "$W/after-head.conf" -w '%{http_code}' "https://127.0.0.1${path}phone.conf")
    [[ $code == 200 ]] || {
        echo "GET after HEAD: $code instead of 200"
        return 1
    }
    cmp "$W/after-head.conf" /etc/seedtunnel/vpn/clients/phone.conf && link_gone "${path}phone.conf"
}

# SFTP settings: WinSCP address with the fingerprint of the server (computed
# here in another way: SHA-256 of the public key, in base64 « URL »), then
# the FileZilla and WinSCP sites downloadable
sftp_config_test() {
    local out path xml ini fingerprint
    fingerprint=$(awk '{ print $2 }' /etc/ssh/ssh_host_ed25519_key.pub | base64 -d \
        | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_')
    out=$(app seedbox sftp-config 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    [[ $out == *"sftp://$SBU;fingerprint=ssh-ed25519-$fingerprint@127.0.0.1:22/"* && $out == *"SHA256:"* ]] || {
        printf 'expected: sftp://%s;fingerprint=ssh-ed25519-%s@127.0.0.1:22/\n%s\n' "$SBU" "$fingerprint" "$out"
        return 1
    }
    out=$(app seedbox sftp-config filezilla 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    path=$(share_path "$out") || return 1
    xml=$(curl -skf --max-time 10 "https://127.0.0.1${path}seedbox-filezilla.xml") || return 1
    [[ $xml == *"<User>$SBU</User>"* && $xml == *"<Protocol>1</Protocol>"* ]] || {
        printf '%s\n' "$xml"
        return 1
    }
    out=$(app seedbox sftp-config winscp 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    path=$(share_path "$out") || return 1
    ini=$(curl -skf --max-time 10 "https://127.0.0.1${path}seedbox-winscp.ini") || return 1
    [[ $ini == *"[Sessions\\Seedbox%20127.0.0.1]"* && $ini == *"HostName=127.0.0.1"* && $ini == *"UserName=$SBU"* ]] || {
        printf '%s\n' "$ini"
        return 1
    }
    # the fingerprint of the server, for WinSCP to check it by itself
    [[ $ini == *"[SshHostKeys]"*"ssh-ed25519@22:127.0.0.1=ssh-ed25519-${fingerprint%%=*}"* ]] || {
        printf '%s\n' "$ini"
        return 1
    }
}

# Key created by seedtunnel for WinSCP: downloaded once as a .ppk file, it opens
# SFTP, and no copy of it stays on the server
generated_key_test() {
    local out path file="seedbox-$SBU.ppk"
    out=$(app seedbox sftp-key new 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    path=$(share_path "$out") || {
        printf 'no link:\n%s\n' "$out"
        return 1
    }
    curl -skf --max-time 10 -o "$W/generated.ppk" "https://127.0.0.1$path$file" || return 1
    grep -q '^PuTTY-User-Key-File-2: ssh-ed25519' "$W/generated.ppk" || {
        head -n 2 "$W/generated.ppk"
        return 1
    }
    link_gone "$path$file" || return 1
    rm -f "$W/generated"
    puttygen "$W/generated.ppk" -O private-openssh-new -o "$W/generated" </dev/null || return 1
    chmod 600 "$W/generated"
    out=$(printf 'ls\n' | sftp -q -i "$W/generated" -oIdentitiesOnly=yes -oBatchMode=yes \
        -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -b - "$SBU@127.0.0.1" 2>&1)
    [[ $out == *watch* ]] || {
        printf 'SFTP with the created key failed:\n%s\n' "$out"
        return 1
    }
    # nothing left behind in the temporary folders
    if find /tmp /var/tmp \( -name key -o -name key.pub -o -name key.ppk \) -print | grep .; then
        echo "a copy of the key stayed on the server"
        return 1
    fi
}

# An address banned by the sshd jail is banned from every port
fail2ban_all_ports_test() {
    local ip=203.0.113.7 rules lines i
    fail2ban-client set sshd banip "$ip" || return 1
    # the ban action runs in the background
    for i in 1 2 3 4 5 6 7 8 9 10; do
        rules=$(nft list ruleset)
        [[ $rules == *"$ip"* ]] && break
        sleep 1
    done
    fail2ban-client set sshd unbanip "$ip" || true
    lines=$(grep -F '@addr-set-sshd' <<<"$rules" || true)
    [[ $rules == *"$ip"* && -n $lines && $lines != *dport* ]] || {
        printf '%s\n' "$lines"
        return 1
    }
}

# The screen of the bans reads what this fail2ban writes (« --with-time »): the
# address, its jail and the end of its ban; then « no address banned »
fail2ban_bans_shown_test() {
    local ip=203.0.113.8 out i
    fail2ban-client set sshd banip "$ip" >/dev/null || return 1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        out=$(app seedbox bans 2>&1)
        [[ $out == *"$ip"* ]] && break
        sleep 1
    done
    fail2ban-client set sshd unbanip "$ip" >/dev/null || true
    grep -qE "^ +1\) +$ip +sshd +([0-9-]{10} )?[0-9]{2}:[0-9]{2} \(in (59 min|60 min|1 h)\)$" <<<"$out" || {
        printf '%s\n' "$out"
        return 1
    }
    out=$(app seedbox bans 2>&1)
    [[ $out == *"No address banned right now."* ]] || {
        printf '%s\n' "$out"
        return 1
    }
}

# Small .torrent (one piece) for a file, written in bencode by hand
make_torrent() {
    local data=$1 out=$2 name size hash
    name=${data##*/}
    size=$(stat -c %s "$data")
    hash=$(sha1sum "$data" | cut -d' ' -f1)
    {
        printf 'd4:infod6:lengthi%se4:name%s:%s12:piece lengthi262144e6:pieces20:' "$size" "${#name}" "$name"
        # shellcheck disable=SC2059 # the 20 bytes of the hash, in binary
        printf "$(sed 's/../\\x&/g' <<<"$hash")"
        printf 'ee'
    } >"$out"
}

# The page of Transmission comes with the style of seedtunnel, served by
# nginx: transmission3-theme.css for Transmission 3 (Debian 12), another page,
# transmission-theme.css for Transmission 4 (Debian 13)
web_style_as_expected() {
    local page version sheet answer
    page=$(curl -sk --max-time 10 -u "$SBU:$PW1" https://127.0.0.1/transmission/web/) || return 1
    version=$(dpkg-query -W -f='${Version}' transmission-daemon)
    version=${version#*:}
    echo "Transmission $version"
    if ((${version%%.*} >= 4)); then sheet=transmission-theme.css; else sheet=transmission3-theme.css; fi
    grep -qF "href=\"/seedtunnel/$sheet\"" <<<"$page" || return 1
    grep -qF '<title>SeedTunnel · Transmission</title>' <<<"$page" || return 1
    answer=$(curl -sk --max-time 10 -u "$SBU:$PW1" -o /dev/null -w '%{http_code} %{content_type}' \
        "https://127.0.0.1/seedtunnel/$sheet")
    [[ $answer == "200 text/css"* ]] || {
        echo "style sheet: $answer"
        return 1
    }
}

# Number of torrents in Transmission, through nginx and its RPC
torrent_count() {
    local session
    session=$(curl -sk -u "$SBU:$PW2" -D - -o /dev/null https://127.0.0.1/transmission/rpc \
        | awk -F': ' 'tolower($1) == "x-transmission-session-id" { print $2 }' | tr -d '\r')
    curl -sk -u "$SBU:$PW2" -H "X-Transmission-Session-Id: $session" \
        -d '{"method":"torrent-get","arguments":{"fields":["id"]}}' https://127.0.0.1/transmission/rpc \
        | jq '.arguments.torrents | length'
}

# Progress of the first torrent in Transmission, in % (100: complete), through
# its RPC (Transmission 4 writes 1.0, Transmission 3 writes 1)
torrent_done() {
    local session
    session=$(curl -sk -u "$SBU:$PW2" -D - -o /dev/null https://127.0.0.1/transmission/rpc \
        | awk -F': ' 'tolower($1) == "x-transmission-session-id" { print $2 }' | tr -d '\r')
    curl -sk -u "$SBU:$PW2" -H "X-Transmission-Session-Id: $session" \
        -d '{"method":"torrent-get","arguments":{"fields":["percentDone"]}}' https://127.0.0.1/transmission/rpc \
        | jq -r '.arguments.torrents[0].percentDone * 100 | floor'
}

# A restore puts the torrents back through watch/: Transmission checks each
# one against the files there. Its file kept in complete/, the torrent of
# phase 1 is found complete, without downloading anything (there is no peer)
torrent_restored_complete() {
    local i progress=""
    for i in $(seq 1 30); do
        progress=$(torrent_done 2>/dev/null || true)
        [[ $progress == 100 ]] && return 0
        sleep 2
    done
    echo "the torrent restored is at ${progress:-?} % instead of 100 %"
    return 1
}

# A .torrent copied into watch/ by root with the rights of its original (600)
# is never added by Transmission: the diagnostics say it
watch_unreadable_test() {
    install -m 600 "$W/test.torrent" "$DATA/watch/unreadable.torrent"
    output_has "unreadable by Transmission" app doctor || {
        rm -f "$DATA/watch/unreadable.torrent"
        return 1
    }
    rm -f "$DATA/watch/unreadable.torrent"
    ! output_has "unreadable by Transmission" app doctor
}

# waits up to 60 s for Transmission to show N torrents
wait_torrents() {
    local i count=""
    for i in $(seq 1 30); do
        count=$(torrent_count 2>/dev/null || true)
        [[ $count == "$1" ]] && return 0
        sleep 2
    done
    echo "Transmission shows ${count:-?} torrent(s) instead of $1"
    return 1
}

# A torrent dropped into watch/ appears in Transmission, and its progress is
# saved (resume file) once Transmission has restarted
torrent_test() {
    head -c 1000 /dev/urandom >"$DATA/complete/test-data.bin"
    make_torrent "$DATA/complete/test-data.bin" "$W/test.torrent"
    install -m 664 "$W/test.torrent" "$DATA/watch/test.torrent"
    wait_torrents 1 || return 1
    systemctl restart transmission-daemon
    ls /var/lib/transmission-daemon/.config/transmission-daemon/resume/*.resume
}

# The full disk protection stops Transmission, then starts it again. Its timer
# of every 5 minutes is stopped meanwhile: it could start Transmission again in
# the middle of the test (seen once on Debian 12)
diskguard_test() {
    local rc=0
    systemctl stop seedtunnel-diskguard.timer
    diskguard_test_steps || rc=1
    systemctl start seedtunnel-diskguard.timer
    return "$rc"
}

diskguard_test_steps() {
    env SEEDTUNNEL_DISKGUARD_STOP_BELOW_GB=100000 PATH=/usr/local/bin:/usr/bin:/bin "$APP" diskguard-check </dev/null || return 1
    if systemctl is-active --quiet transmission-daemon; then
        echo "Transmission still running"
        return 1
    fi
    [[ -e /run/seedtunnel-diskguard.stopped ]] || return 1
    output_has 'disk almost full' app doctor || return 1
    env SEEDTUNNEL_DISKGUARD_START_ABOVE_GB=0 PATH=/usr/local/bin:/usr/bin:/bin "$APP" diskguard-check </dev/null || return 1
    systemctl is-active --quiet transmission-daemon && [[ ! -e /run/seedtunnel-diskguard.stopped ]] || return 1
    # Transmission checks the disk before starting (boot included)
    systemctl show transmission-daemon -p ExecStartPre | grep -q diskguard-prestart || return 1
    if env SEEDTUNNEL_DISKGUARD_STOP_BELOW_GB=100000 PATH=/usr/local/bin:/usr/bin:/bin "$APP" diskguard-prestart </dev/null; then
        echo "start allowed on an almost full disk"
        return 1
    fi
    rm -f /run/seedtunnel-diskguard.stopped
}

# « seedtunnel apply » puts back in order a file changed by hand, says it and
# keeps a copy of the version changed by hand (root only)
apply_test() {
    local out copy
    echo '# changed by hand' >>/etc/fail2ban/jail.d/seedtunnel.local
    out=$(app doctor 2>&1) || true
    grep -qF "/etc/fail2ban/jail.d/seedtunnel.local changed by hand" <<<"$out" || {
        echo "doctor said nothing"
        return 1
    }
    out=$(app apply 2>&1) || true
    grep -qF "Restarting fail2ban" <<<"$out" && grep -qF "seedtunnel.local was changed by hand" <<<"$out" || {
        echo "$out"
        return 1
    }
    ! grep -q 'changed by hand' /etc/fail2ban/jail.d/seedtunnel.local || return 1
    copy=$(ls /etc/seedtunnel/changed-by-hand/_etc_fail2ban_jail.d_seedtunnel.local.* | tail -n 1)
    grep -q 'changed by hand' "$copy" && [[ $(stat -c %a /etc/seedtunnel/changed-by-hand) == 700 ]]
}

# Without the password, or with a wrong one: still a 401 with the header that
# makes the browser ask, and the page « access denied », which tells nothing
# of what is behind; that page is never served on its own
denied_page_as_expected() {
    local headers
    headers=$(curl -sk --max-time 10 -D - -o "$W/denied.html" https://127.0.0.1/transmission/web/) || return 1
    # the name sent with the request for the password tells nothing either
    grep -qiE '^HTTP/[0-9.]+ 401' <<<"$headers" && grep -qi '^www-authenticate: Basic realm="Restricted"' <<<"$headers" \
        && ! grep -qi "seedbox\|seedtunnel\|transmission" <<<"$headers" || {
        echo "$headers"
        return 1
    }
    grep -q "Access denied" "$W/denied.html" && ! grep -qi "transmission\|seedtunnel" "$W/denied.html" || return 1
    [[ $(curl -sk --max-time 10 -u "$SBU:wrong" -o "$W/denied.html" -w '%{http_code}' https://127.0.0.1/) == 401 ]] || return 1
    grep -q "Access denied" "$W/denied.html" || return 1
    [[ $(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' https://127.0.0.1/seedtunnel/denied.html) == 404 ]]
}

# Download of the latest backup by a one-time link, then decryption
backup_share_test() {
    local out path name
    rm -f /etc/seedtunnel/backup.downloaded
    out=$(app backup share 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    path=$(share_path "$out") || return 1
    name=$(curl -sk --max-time 10 "https://127.0.0.1$path" | grep -oE 'href="seedtunnel-[^"]+\.enc"' | cut -d'"' -f2)
    [[ -n $name ]] || return 1
    # a HEAD request (a link checker) does not count as a download
    curl -sk --max-time 10 -I -o /dev/null "https://127.0.0.1$path$name" || return 1
    sleep 1
    if [[ -e /etc/seedtunnel/backup.downloaded ]]; then
        echo "a HEAD request was recorded as a download"
        return 1
    fi
    curl -skf --max-time 30 -o "$W/downloaded.enc" "https://127.0.0.1$path$name" || return 1
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$W/downloaded.enc" -pass file:"$W/passphrase" \
        | tar -tzf - >"$W/content.txt" || return 1
    grep -qx 'etc/seedtunnel/vpn.conf' "$W/content.txt" || return 1
    grep -q 'transmission-daemon/resume/' "$W/content.txt" || return 1
    link_gone "$path$name" || return 1
    # the download is recorded for the reminder of the diagnostics
    [[ -e /etc/seedtunnel/backup.downloaded ]]
}

# Weekly backup: the timer runs it, and only the last 4 are kept
backup_auto_test() {
    local i
    app backup auto on --passphrase-file "$W/passphrase" || return 1
    systemctl is-enabled --quiet seedtunnel-backup.timer || return 1
    for i in 1 2 3 4 5; do
        systemctl start seedtunnel-backup.service || return 1
        sleep 1
    done
    ls /var/backups/seedtunnel/
    (($(ls /var/backups/seedtunnel/*-auto.tar.gz.enc | wc -l) == 4))
}

summary() {
    printf '\n\033[1m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
    ((FAIL == 0))
}

phase1() {
    mkdir -p "$W"
    chmod 700 "$W"
    printf '%s\n' "$PW1" >"$W/password"
    cat >"$W/ci.conf" <<EOF
VPN_PUBLIC_ADDRESS=192.168.250.1
VPN_PORT=51820
VPN_DNS=quad9
VPN_CLIENTS="phone"
SEEDBOX_USER=$SBU
SEEDBOX_PASSWORD_FILE=$W/password
SEEDBOX_DOMAIN=127.0.0.1
SEEDBOX_DATA_DIR=$DATA
SEEDBOX_LETSENCRYPT=no
EOF
    chmod 600 "$W/ci.conf" "$W/password"

    step "General ($(. /etc/os-release && printf '%s' "$PRETTY_NAME"))"
    check "system recognised (header, diagnostics)" system_named
    check "seedtunnel version" output_has "seedtunnel $(sed -n 's/^APP_VERSION="\(.*\)"$/\1/p' "${APP%/*}/lib/common.sh")" app version
    check "seedtunnel help" output_has "vpn add NAME" app help
    check "help: new commands" output_has "backup auto on|off|status" app help
    check "help in French" output_has "Utilisation : seedtunnel" env SEEDTUNNEL_LANG=fr "$APP" help
    check_fails "unknown command refused" app whatever
    check "error message in French" output_has "Commande inconnue" env SEEDTUNNEL_LANG=fr "$APP" whatever

    if command -v ufw >/dev/null; then
        step "ufw on: nothing installed"
        check "ufw turned on" ufw --force enable
        check "VPN refused, says « ufw disable »" output_has "sudo ufw disable" app vpn install --config "$W/ci.conf"
        check "seedbox refused" output_has "sudo ufw disable" app seedbox install --config "$W/ci.conf"
        check "firewall refused" output_has "sudo ufw disable" app firewall enable --yes
        check "restore refused" output_has "sudo ufw disable" app restore "$W/ci.conf"
        check_fails "nothing installed" bash -c "test -e /etc/seedtunnel/vpn.conf || test -e /etc/seedtunnel/seedbox.conf \
            || dpkg-query -W -f='\${Status}\n' wireguard-tools nginx fail2ban 2>/dev/null | grep -q ' installed$'"
        # installed but off, as on Ubuntu Server: no longer in the way
        check "ufw turned off" ufw disable
    fi

    step "VPN: installation from a configuration file"
    install -m 644 "$W/ci.conf" "$W/open.conf"
    check_fails "configuration file readable by others refused" app vpn install --config "$W/open.conf"
    check_fails "nothing installed by it" test -e /etc/seedtunnel/vpn.conf
    check "installation" app vpn install --config "$W/ci.conf"
    check "WireGuard service running" systemctl is-active --quiet wg-quick@wg0
    check 'client "phone" created' test -s /etc/seedtunnel/vpn/clients/phone.conf
    check "port 60001 forwarded to 10.8.0.2" output_has "dport 60001 dnat to 10.8.0.2" nft list table ip seedtunnel
    check_fails "wg0.conf runs no command (PostUp, PostDown)" grep -qE '^(Pre|Post)(Up|Down)' /etc/wireguard/wg0.conf
    check "NAT rules loaded by systemd when wg0 starts, removed when it stops" vpn_nat_follows_wg0
    check "IPv4 routing on" test "$(sysctl -n net.ipv4.ip_forward)" = 1
    check "kernel network settings hardened" net_hardened
    check "all of them, as the diagnostics check them (IPv6 included)" seedtunnel_function net_hardening_in_force
    check "hardening saved for the next boot" test -s /etc/sysctl.d/90-seedtunnel-network.conf
    check '« seedtunnel » command found even after a su without a dash' \
        env PATH=/usr/local/bin:/usr/bin:/bin bash -c 'command -v seedtunnel'

    step "VPN: same run again (idempotence)"
    md5sum /etc/seedtunnel/vpn/server.key /etc/wireguard/wg0.conf >"$W/vpn.md5"
    check "no change when run again" nothing_changed app vpn install --config "$W/ci.conf"
    check "keys and configuration unchanged" md5sum -c --quiet "$W/vpn.md5"

    step "VPN: commands"
    check "vpn add laptop" app vpn add laptop
    check "vpn list shows laptop" output_has "laptop" app vpn list
    check "vpn list in French" output_has "DERNIÈRE CONNEXION" env SEEDTUNNEL_LANG=fr PATH=/usr/local/bin:/usr/bin:/bin "$APP" vpn list
    check_fails "vpn remove without --yes refused" app vpn remove laptop
    check "vpn remove --yes" app vpn remove laptop --yes
    check_fails "laptop is gone" test -e /etc/seedtunnel/vpn/clients/laptop.env
    check "vpn show phone" output_has "[Interface]" app vpn show phone
    check "vpn show phone: the QR code fits in 80 columns" vpn_qr_test
    check_fails "invalid client name refused" app vpn add "invalid name!"
    check "vpn share without a seedbox: refused, says what to do" output_has "seedtunnel vpn show phone" app vpn share phone
    check "vpn dns: Quad9 in use" output_has "DNS of the clients: Quad9 · 9.9.9.9, 149.112.112.112." app vpn dns
    check "vpn dns cloudflare: in the file of the clients" vpn_dns_test

    step "VPN: end-to-end tunnel"
    check "a client connects and reaches 10.8.0.1" tunnel_test
    # for phase 2: a backup of this server while it has its VPN only
    printf 'a test passphrase\n' >"$W/vpn-only.pass"
    chmod 600 "$W/vpn-only.pass"
    check "backup of the VPN alone (used in phase 2)" app backup --output "$W/vpn-only.enc" --passphrase-file "$W/vpn-only.pass"

    step "Seedbox: installation from a configuration file"
    check "installation" app seedbox install --config "$W/ci.conf"
    check "Transmission running" systemctl is-active --quiet transmission-daemon
    check "nginx running" systemctl is-active --quiet nginx
    check "fail2ban running" systemctl is-active --quiet fail2ban
    check "full disk protection on" systemctl is-active --quiet seedtunnel-diskguard.timer
    check "web without credentials: 401" http_is 401 /transmission/web/
    check "web with credentials: 200" http_is 200 /transmission/web/ -u "$SBU:$PW1"
    check "Transmission answers behind nginx (409)" http_is 409 /transmission/rpc -u "$SBU:$PW1"
    check "wrong password refused" http_is 401 /transmission/web/ -u "$SBU:wrong"
    check "page « access denied »: still a 401 asking for the password, nothing tells what is behind" denied_page_as_expected
    check "home page: the password first (401)" http_is 401 /
    check "home page with the password: to the web interface (302)" http_is 302 / -u "$SBU:$PW1"
    check "web interface: style of seedtunnel on Transmission 3 and 4" web_style_as_expected
    dpkg-query -W -f='    ${Package} ${Version}\n' transmission-daemon nginx openssh-server fail2ban 2>/dev/null || true
    check "no password in clear in the configuration" bash -c "! grep -rqF -- '$PW1' /etc/seedtunnel /etc/nginx /etc/transmission-daemon"
    # fresh system: the site « default » is the one of the package, recognised
    check "site « default » of nginx (as installed) turned off" bash -c "[[ ! -e /etc/nginx/sites-enabled/default ]]"
    check "Transmission locked down by systemd" output_has "ProtectSystem=strict" systemctl show transmission-daemon -p ProtectSystem
    check "Transmission waits for the disk of the data" output_has "$DATA" systemctl show transmission-daemon -p RequiresMountsFor
    # Ubuntu 26.04: its AppArmor profile confines Transmission; elsewhere, nothing
    if [[ -f /etc/apparmor.d/transmission ]] && grep -q 'local/transmission-daemon' /etc/apparmor.d/transmission; then
        check "AppArmor: Transmission allowed in the data folder" grep -qxF "\"$DATA/**\" rwk," /etc/apparmor.d/local/transmission-daemon
    else
        check_fails "no AppArmor rules without the profile" test -e /etc/apparmor.d/local/transmission-daemon
    fi

    step "Seedbox: same run again (idempotence)"
    check "no service restarted" nothing_changed app seedbox install --config "$W/ci.conf"

    step "One-time download links"
    check "vpn share: page, single download, then the link is gone" share_test
    check "another form of the address (?x) also uses up the link" share_variant_test
    check "no partial download (Range ignored)" share_no_range_test
    check "two requests on the same connection: the file only once" share_same_connection_test
    check "HEAD refused (405) without using the link up" share_head_test
    check "watcher killed: the link is deleted anyway" share_watcher_killed_test
    check "tokens of the links hidden in the access log of nginx" share_log_test
    check "seedbox sftp-config: WinSCP address with fingerprint, FileZilla and WinSCP files" sftp_config_test
    check "list of links impossible" http_is 403 /share/
    check "unknown token: 404" http_is 404 /share/0123456789abcdef0123456789abcdef/

    step "SFTP"
    check "connection and folders visible" output_has "watch" sftp_password "$PW1" "ls"
    check "upload of a file into documents/" sftp_password "$PW1" "put /etc/hostname documents/test.txt"
    check "the file arrived" test -f "$DATA/documents/test.txt"
    check_fails "cannot leave the folder (chroot)" sftp_password "$PW1" "ls /etc"
    check_fails "no SSH shell" sshpass -p "$PW1" ssh -oStrictHostKeyChecking=no \
        -oUserKnownHostsFile=/dev/null -oPubkeyAuthentication=no "$SBU@127.0.0.1" id

    step "SFTP: SSH keys"
    rm -f "$W/key" "$W/key.pub"
    ssh-keygen -q -t ed25519 -N '' -f "$W/key"
    check "key added" app seedbox sftp-key add "$W/key.pub"
    check "connection with the key" output_has "watch" sftp_key "ls"
    check "SFTP password turned off" app seedbox sftp-password off
    check_fails "connection with the password refused" sftp_password "$PW1" "ls"
    check "web still reachable with the password" http_is 200 /transmission/web/ -u "$SBU:$PW1"
    check "SFTP password allowed again" app seedbox sftp-password on
    check "sftp-key new: .ppk downloaded once, opens SFTP, no copy left" generated_key_test

    step "Change of password"
    check "seedbox password (standard input)" bash -c "printf '%s\n' '$PW2' | '$APP' seedbox password"
    check "new password accepted" http_is 409 /transmission/rpc -u "$SBU:$PW2"
    check "old password refused" http_is 401 /transmission/web/ -u "$SBU:$PW1"
    check "SFTP with the new password" output_has "watch" sftp_password "$PW2" "ls"
    printf '%s\n' "$PW2" >"$W/password"
    check "account renamed, works, then back to its name (never left suspended)" rename_test

    step "Torrents"
    check "a .torrent dropped into watch/ is added, its progress saved" torrent_test
    check "doctor: a .torrent of watch/ unreadable by Transmission is said" watch_unreadable_test

    step "fail2ban"
    check "sshd, nginx-http-auth and recidive jails" bash -c \
        "fail2ban-client status | grep -q sshd && fail2ban-client status | grep -q nginx-http-auth && fail2ban-client status | grep -q recidive"
    check "SSH: ban from every port, whatever the port of SSH" fail2ban_all_ports_test
    check "bans: the address, its jail and the end of its ban, then « no address banned »" fail2ban_bans_shown_test

    step "Firewall"
    check_fails "without --yes nor terminal: refused" app firewall enable
    check "enabling" app firewall enable --yes
    nft list table inet seedtunnel_fw >"$W/fw.txt"
    check "SSH allowed" grep -Eq 'tcp dport (\{ )?22( \})? accept' "$W/fw.txt"
    check "VPN allowed" grep -q 'udp dport 51820 accept' "$W/fw.txt"
    check "web allowed" grep -q '80, 443' "$W/fw.txt"
    check "default policy: drop" grep -q 'policy drop' "$W/fw.txt"
    check "loaded again at boot" systemctl is-enabled --quiet seedtunnel-firewall.service
    check "WireGuard tunnel through the firewall" tunnel_test
    check "loaded at boot after nftables.service" output_has "nftables.service" systemctl show seedtunnel-firewall.service -p After
    check "firewall rules: what is loaded, in words, with the port of the client" firewall_rules_test
    check "report by link: nothing private, no password, no key, link used once" report_link_test
    check "confirmation: real SSH login recognised, fake message refused" firewall_proof_test

    step "Full disk protection"
    check "Transmission stopped under the threshold, started again above" diskguard_test

    step "Applying the configuration again (seedtunnel apply)"
    check "puts back in order a change made by hand" apply_test
    check "run again: no change" nothing_changed app apply
    check "a timer turned off by hand is put back in service" timers_put_back_test
    check "unknown command refused before anything is done" commands_refused_first_test

    summary
}

phase2() {
    step "Diagnostics"
    check "seedtunnel doctor without problem" app doctor
    check "doctor with an IP: one warning, that asks for a domain name" doctor_ip_test
    # SSH port changed in the configuration without updating the firewall
    printf 'Port 2222\n' >/etc/ssh/sshd_config.d/zz-test-port.conf
    check "doctor reports an SSH port closed by the firewall" output_has "port 2222, closed by the firewall" app doctor
    rm -f /etc/ssh/sshd_config.d/zz-test-port.conf

    step "Backups"
    printf 'a test passphrase\n' >"$W/passphrase"
    chmod 600 "$W/passphrase"
    md5sum /etc/seedtunnel/vpn/server.key /etc/seedtunnel/vpn/clients/phone.conf /etc/seedtunnel/seedbox.secrets >"$W/before.md5"
    check "encrypted backup" app backup --passphrase-file "$W/passphrase"
    check "archive unreadable without the passphrase" bash -c "! tar -tzf /var/backups/seedtunnel/*.enc 2>/dev/null"
    check "doctor: reminder to download a backup" output_has "No backup downloaded" app doctor
    check "backup share: one-time link, then decrypted" backup_share_test
    check "weekly backup: run by the timer, only the last 4 kept" backup_auto_test
    check_fails "weekly backup off without --yes nor terminal: refused" app backup auto off
    check "weekly backup still on" systemctl is-enabled --quiet seedtunnel-backup.timer
    cp "$(ls -1t /var/backups/seedtunnel/*-auto.tar.gz.enc | head -n 1)" "$W/backup.enc"

    step "Removal, then restore"
    check "backup without the seedbox of this server: refused, nothing changed" restore_missing_part_test
    check "removing the seedbox" app seedbox uninstall --yes
    check "removing the VPN" app vpn uninstall --yes
    check "turning the firewall off" app firewall disable --yes
    check_fails "nothing left to back up: weekly backup turned off" systemctl is-enabled --quiet seedtunnel-backup.timer
    printf 'wrong passphrase\n' >"$W/wrong"
    chmod 600 "$W/wrong"
    check_fails "wrong passphrase refused" app restore "$W/backup.enc" --passphrase-file "$W/wrong" --yes
    check "restore" app restore "$W/backup.enc" --passphrase-file "$W/passphrase" --yes
    check "same VPN keys, clients and hashes" md5sum -c --quiet "$W/before.md5"
    check "WireGuard running" systemctl is-active --quiet wg-quick@wg0
    check "the old client connects without any change" tunnel_test
    check "seedbox password kept" http_is 409 /transmission/rpc -u "$SBU:$PW2"
    check "list of torrents restored" wait_torrents 1
    check "torrent restored through watch/: its file checked, complete without downloading" torrent_restored_complete
    check "firewall restored" systemctl is-active --quiet seedtunnel-firewall.service
    check "weekly backup restored" systemctl is-enabled --quiet seedtunnel-backup.timer
    # as seen on a real server: a backup made before the weekly backup was
    # turned on, restored while it is on
    check "older backup restored: the weekly backup keeps its passphrase" restore_older_backup_test
    check "restore without a file and without a terminal: the usage, nothing done" output_has "Usage: seedtunnel restore FILE" app restore
    check "magnet links of a backup: through watch/ (Transmission 4), to add by hand (Transmission 3)" restore_magnet_test
    check "doctor: settings replaced by a restore said, no longer once deleted" restore_leftovers_test

    step "Removal"
    check "seedbox" app seedbox uninstall --yes
    check_fails "removal with an IP: certbot not asked for a certificate that never existed" grep -q "No certificate found" /var/log/seedtunnel.log
    check "VPN" app vpn uninstall --yes
    check "firewall" app firewall disable --yes
    check_fails "no SFTP rule left" test -e /etc/ssh/sshd_config.d/seedtunnel-seedbox.conf
    check_fails "no user $SBU left" id "$SBU"
    check_fails "no wg0 interface left" ip link show wg0
    check_fails "no addition left to the service of WireGuard" test -e /etc/systemd/system/wg-quick@wg0.service.d/seedtunnel.conf
    check_fails "no full disk protection left" systemctl cat seedtunnel-diskguard.timer
    check_fails "no weekly backup left" systemctl cat seedtunnel-backup.timer
    check "backups kept" bash -c "ls /var/backups/seedtunnel/*.enc"
    check "data kept" test -f "$DATA/documents/test.txt"
    # started on demand by ssh.socket (Ubuntu), or always running (Debian)
    check "SSH still running" bash -c 'systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket'
    check_fails "packages installed by seedtunnel removed" bash -c "dpkg-query -W -f='\${Status}\n' wireguard-tools nginx nginx-common transmission-daemon 2>/dev/null | grep -q ' installed$'"
    check "package there before seedtunnel kept (qrencode)" output_has "install ok installed" dpkg-query -W -f='${Status}' qrencode

    summary
}

case ${1-} in
    phase1) phase1 ;;
    phase2) phase2 ;;
    *)
        echo "Usage: $0 phase1|phase2" >&2
        exit 2
        ;;
esac
