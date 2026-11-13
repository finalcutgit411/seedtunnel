#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — seedbox module
#
#  Transmission  : only listens on 127.0.0.1, protected by its own password,
#                  and locked down by systemd (ProtectSystem=strict…)
#  nginx         : the only way in, HTTPS + password (same login)
#  Let's Encrypt : « webroot » validation through nginx, so the automatic
#                  renewal works (certbot.timer); self-signed as a fallback
#  SFTP          : replaces FTP; the user is locked in the data folder, with
#                  no shell and no tunnel; password and/or SSH keys
#  fail2ban      : SSH/SFTP, web password, repeat offenders (nftables)
#
#  Passwords are never stored in clear: only their hashes (system, nginx,
#  Transmission) are kept in /etc/seedtunnel/seedbox.secrets, so everything
#  can be applied again or restored without asking for the password.
#
#  Folders: <data>/complete    finished downloads (and shared)
#           <data>/incomplete  downloads in progress
#           <data>/watch       drop a .torrent here, it starts by itself
#           <data>/documents   personal space (Transmission has no access)
# =============================================================================

SEEDBOX_CONF_FILE="$APP_STATE_DIR/seedbox.conf"
SEEDBOX_SECRETS_FILE="$APP_STATE_DIR/seedbox.secrets"
SEEDBOX_SSL_DIR="$APP_STATE_DIR/ssl"
NGINX_SITE="/etc/nginx/sites-available/seedtunnel"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/seedtunnel"
NGINX_HTPASSWD="/etc/nginx/seedtunnel.htpasswd"
# site installed by the nginx package, replaced by the seedbox
NGINX_DEFAULT_SITE="/etc/nginx/sites-enabled/default"
NGINX_DEFAULT_SOURCE="/etc/nginx/sites-available/default"
SSHD_SEEDBOX_CONF="/etc/ssh/sshd_config.d/seedtunnel-seedbox.conf"
SFTP_KEYS_DIR="/etc/ssh/seedtunnel_authorized_keys"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/seedtunnel.local"
FAIL2BAN_MAIN_CONF="/etc/fail2ban/fail2ban.d/seedtunnel.local"
TRANSMISSION_DROPIN="/etc/systemd/system/transmission-daemon.service.d/seedtunnel.conf"
TRANSMISSION_USER="debian-transmission"
# torrents, progress (« resume ») and settings of Transmission (Debian)
TRANSMISSION_STATE_DIR="/var/lib/transmission-daemon/.config/transmission-daemon"
# Settings of Transmission on Debian and Ubuntu (TRANSMISSION_STATE_DIR has a
# link to it)
TRANSMISSION_ETC_SETTINGS="/etc/transmission-daemon/settings.json"
# Set by a restore: the extracted backup whose torrents and settings of
# Transmission are put back the next time Transmission is stopped for its
# settings (one restart only)
TRANSMISSION_RESTORE_FROM=""
TRANSMISSION_RPC_PORT=9091
LETSENCRYPT_WEBROOT="/var/www/letsencrypt"
LETSENCRYPT_CERT_NAME="seedtunnel"
LETSENCRYPT_ROOT="/etc/letsencrypt"
LETSENCRYPT_DIR="$LETSENCRYPT_ROOT/live/$LETSENCRYPT_CERT_NAME"
# the VPN clients use 60001 and above
TORRENT_PORT=60000
# password being changed (never written to disk)
SEEDBOX_NEW_PASSWORD=""

# Settings imposed on Transmission. DHT, PEX, LPD and uTP are off: suited to
# private trackers (can be changed in the web interface, Preferences).
read -r -d '' TRANSMISSION_SETTINGS_FILTER <<'JQ' || true
{
  "download-dir": $dl,
  "incomplete-dir": $inc,
  "incomplete-dir-enabled": true,
  "watch-dir": $watch,
  "watch-dir-enabled": true,
  "rpc-enabled": true,
  "rpc-bind-address": "127.0.0.1",
  "rpc-port": $rpcport,
  "rpc-authentication-required": true,
  "rpc-username": $user,
  "rpc-password": $hash,
  "rpc-whitelist-enabled": true,
  "rpc-whitelist": "127.0.0.1,::1",
  "rpc-host-whitelist-enabled": false,
  "peer-port": $peerport,
  "peer-port-random-on-start": false,
  "port-forwarding-enabled": false,
  "dht-enabled": false,
  "pex-enabled": false,
  "lpd-enabled": false,
  "utp-enabled": false,
  "umask": 2
}
JQ

seedbox_load() {
    SEEDBOX_USER=""
    SEEDBOX_DOMAIN=""
    SEEDBOX_DATA_DIR=""
    # selfsigned | letsencrypt | staging: certificate served right now
    SEEDBOX_CERTIFICATE="selfsigned"
    # auto | yes | no: should a Let's Encrypt certificate be requested?
    SEEDBOX_LETSENCRYPT="auto"
    # production | staging: Let's Encrypt servers used
    SEEDBOX_LETSENCRYPT_SERVER="production"
    # yes | no: does SFTP accept the password (otherwise SSH keys only)
    SEEDBOX_SFTP_PASSWORD="yes"
    SEEDBOX_HASH_SYSTEM=""
    SEEDBOX_HASH_WEB=""
    SEEDBOX_HASH_TRANSMISSION=""
    state_read "$SEEDBOX_CONF_FILE"
    state_read "$SEEDBOX_SECRETS_FILE"
}

seedbox_save() {
    state_write "$SEEDBOX_CONF_FILE" SEEDBOX_USER SEEDBOX_DOMAIN SEEDBOX_DATA_DIR SEEDBOX_CERTIFICATE \
        SEEDBOX_LETSENCRYPT SEEDBOX_LETSENCRYPT_SERVER SEEDBOX_SFTP_PASSWORD
}

seedbox_installed() { [[ -f $SEEDBOX_CONF_FILE ]]; }

seedbox_require_installed() {
    seedbox_installed || die 'The seedbox is not installed:  seedtunnel seedbox install'
}

# Real settings file of Transmission: the one in /etc that the link of Debian
# points to, or a file of its own in its folder. Nothing else: the account of
# Transmission can change this link (its folder belongs to it), and root would
# then read, write and back up the file it points to. Status 1 otherwise.
transmission_settings_file() {
    local link="$TRANSMISSION_STATE_DIR/settings.json" real
    if [[ ! -e $link && ! -L $link ]]; then
        printf '%s' "$TRANSMISSION_ETC_SETTINGS"
        return 0
    fi
    real=$(readlink -f -- "$link" 2>/dev/null || true)
    if [[ -L $link && $real == "$TRANSMISSION_ETC_SETTINGS" ]]; then
        printf '%s' "$real"
    elif [[ ! -L $link && -f $link ]]; then
        printf '%s' "$link"
    else
        err 'The settings of Transmission point somewhere unexpected: %s → %s. To put the link back:  ln -sfn %s %s' \
            "$link" "${real:-?}" "$TRANSMISSION_ETC_SETTINGS" "$link"
        return 1
    fi
}

# transmission_settings_write FILE SOURCE — the settings of Transmission
# replaced by those of SOURCE, written by the account of Transmission, never
# by root: a link it put in its folders could only lead it where it can write
# already. Replaced by renaming, never half-written, readable by it alone.
transmission_settings_write() {
    runuser -u "$TRANSMISSION_USER" -- sh -c 'umask 077 && cat >"$1.new" && mv -f "$1.new" "$1"' sh "$1" <"$2"
}

seedbox_certificate_label() {
    case $SEEDBOX_CERTIFICATE in
        letsencrypt) printf "Let's Encrypt" ;;
        staging) t "Let's Encrypt (test server, not trusted by browsers)" ;;
        *) t 'self-signed' ;;
    esac
}

# --- Checks ---------------------------------------------------------------------------

seedbox_is_valid_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

seedbox_is_valid_domain() {
    [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || is_ipv4 "$1"
}

# IPv4 addresses of a name, asked to a public DNS server (not the local cache)
dns_ipv4_addresses() {
    dig +short +time=3 +tries=2 A "$1" @9.9.9.9 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' || true
}

dns_points_here() {
    [[ -n $2 ]] && grep -qxF "$2" <<<"$(dns_ipv4_addresses "$1")"
}

# Suggests a name that already points to this server: name of the machine, or
# reverse name given by the provider (e.g. vps-1234abcd.vps.ovh.net). Else the IP.
seedbox_guess_domain() {
    local ip=$1 candidate reverse
    reverse=$(dig +short -x "$ip" @9.9.9.9 2>/dev/null | sed -n '1s/\.$//p' || true)
    for candidate in "$(hostname --fqdn 2>/dev/null || true)" "$reverse"; do
        candidate=${candidate,,}
        if [[ -n $candidate ]] && ! is_ipv4 "$candidate" && seedbox_is_valid_domain "$candidate" \
            && dns_points_here "$candidate" "$ip"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '%s' "$ip"
}

# Biggest local partition; if it is « / », /srv/seedbox is used
seedbox_default_data_dir() {
    local mount
    mount=$(df -lP -x tmpfs -x devtmpfs -x overlay -x squashfs -x vfat 2>/dev/null \
        | awk 'NR > 1 { print $4, $6 }' | sort -nr | awk 'NR == 1 { print $2 }' || true)
    case $mount in
        "" | / | /boot*) printf '/srv/seedbox' ;;
        *) printf '%s/seedbox' "${mount%/}" ;;
    esac
}

# sshd requires every folder in the path of the SFTP chroot to belong to root
# and to be writable by nobody else.
seedbox_check_data_dir() {
    local path=$1 current="" part owner mode
    local -a parts
    if [[ ! $path =~ ^(/[A-Za-z0-9._-]+)+$ || $path == *..* ]]; then
        warn 'Invalid path: /folder/subfolder (letters, digits, . _ -).'
        return 1
    fi
    case $path in
        /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /media | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
            warn 'Choose a subfolder, not a system folder (e.g. %s/seedbox).' "$path"
            return 1
            ;;
    esac
    IFS=/ read -r -a parts <<<"${path#/}"
    for part in "${parts[@]}"; do
        current+="/$part"
        # the rest will be created by the script (root, 755)
        [[ -e $current ]] || break
        if [[ ! -d $current ]]; then
            warn '%s exists but is not a folder.' "$current"
            return 1
        fi
        read -r owner mode < <(stat -L -c '%u %a' "$current")
        if ((owner != 0 || (8#$mode & 8#022))); then
            warn '%s must belong to root and be writable only by root (needed by the locked SFTP).' "$current"
            return 1
        fi
    done
    return 0
}

# seedbox_check_web_ports [links] — no other program on 80 or 443 (links:
# for the site of the links)
# shellcheck disable=SC2120 # « links » comes from lib/share.sh and lib/backup.sh
seedbox_check_web_ports() {
    local out
    out=$(ss -Hltnp '( sport = :80 or sport = :443 )' 2>/dev/null || true)
    # each listening line: nginx on one port does not cover another program on the other
    out=$(grep -v nginx <<<"$out" || true)
    if [[ -n $out && ${1-} == links ]]; then
        die 'Ports 80/443 are already used by another program:\n%s\n  Stop it (apache2 for example) before installing the site of the links.' "$out"
    elif [[ -n $out ]]; then
        die 'Ports 80/443 are already used by another program:\n%s\n  Stop it (apache2 for example) before installing the seedbox.' "$out"
    fi
}

# --- Passwords (hashes only) -------------------------------------------------------

# Transmission stores « { » + sha1(password + salt) in hexadecimal + a salt of
# 8 characters. It is computed here: the password is never written in clear.
transmission_password_hash() {
    local salt="" random sum
    while ((${#salt} < 8)); do
        random=$(openssl rand -base64 12)
        salt+=${random//[^A-Za-z0-9]/}
    done
    salt=${salt:0:8}
    sum=$(printf '%s%s' "$1" "$salt" | sha1sum)
    printf '{%s%s' "${sum%% *}" "$salt"
}

# Computes and saves the three hashes of SEEDBOX_NEW_PASSWORD (the user must exist)
seedbox_hash_password() {
    # printf is built into bash: the password does not show in « ps »
    printf '%s:%s\n' "$SEEDBOX_USER" "$SEEDBOX_NEW_PASSWORD" | chpasswd
    SEEDBOX_HASH_SYSTEM=$(getent shadow "$SEEDBOX_USER" | cut -d: -f2)
    SEEDBOX_HASH_WEB=$(printf '%s\n' "$SEEDBOX_NEW_PASSWORD" | openssl passwd -6 -stdin)
    SEEDBOX_HASH_TRANSMISSION=$(transmission_password_hash "$SEEDBOX_NEW_PASSWORD")
    state_write "$SEEDBOX_SECRETS_FILE" SEEDBOX_HASH_SYSTEM SEEDBOX_HASH_WEB SEEDBOX_HASH_TRANSMISSION
}

# Is this password already the saved one? (running again changes nothing)
seedbox_password_matches() {
    local salt computed
    [[ $SEEDBOX_HASH_WEB == '$6$'* ]] || return 1
    salt=${SEEDBOX_HASH_WEB#\$6\$}
    salt=${salt%%\$*}
    computed=$(printf '%s\n' "$1" | openssl passwd -6 -salt "$salt" -stdin)
    [[ $computed == "$SEEDBOX_HASH_WEB" ]]
}

# --- Questions (interactive mode) ---------------------------------------------------

# Status 1: the user went back (empty answer), nothing asked further
seedbox_ask_user() {
    local current=${1-} name
    while true; do
        ask_back name 'User name (web and SFTP)' "${SEEDBOX_USER:-lancelot}" || return 1
        if ! seedbox_is_valid_user "$name"; then
            warn 'Lowercase letters, digits, - and _ only (32 characters at most).'
        elif [[ $name != "$current" ]] && id "$name" &>/dev/null; then
            warn '"%s" already exists on this system: choose another name.' "$name"
        else
            break
        fi
    done
    OPT_NEW_USER=$name
    ask_password SEEDBOX_NEW_PASSWORD
}

# Asks for the domain name and checks that it points to this server.
# Sets SEEDBOX_DOMAIN, and SEEDBOX_LETSENCRYPT: auto if Let's Encrypt has a
# chance, otherwise no. An empty answer or B goes back, with status 1, and
# nothing is changed. « change »: the seedbox is already installed.
seedbox_ask_domain() {
    local ip=$1 mode=${2-} ips choice answer default=$SEEDBOX_DOMAIN
    if [[ $mode == change ]]; then default=""; fi
    text seedbox_domain_help
    echo
    while true; do
        if [[ $mode == change ]]; then
            ask_back answer 'New domain name or IP' "$default" || return 1
        else
            ask_back answer 'Domain name or IP' "$default" || return 1
        fi
        answer=${answer,,}
        answer=${answer#http://}
        answer=${answer#https://}
        answer=${answer%/}
        if ! seedbox_is_valid_domain "$answer"; then
            warn 'Invalid domain name.'
            continue
        fi
        default=$answer
        if is_ipv4 "$answer"; then
            SEEDBOX_DOMAIN=$answer
            SEEDBOX_LETSENCRYPT=no
            return 0
        fi
        ips=$(dns_ipv4_addresses "$answer")
        if [[ -z $ips ]]; then
            warn '"%s" does not point to any IPv4 address.' "$answer"
        elif ! grep -qxF "$ip" <<<"$ips"; then
            warn '"%s" points to %s, not to this server (%s).' "$answer" "${ips//$'\n'/, }" "$ip"
        else
            ok '"%s" points to this server (%s).' "$answer" "$ip"
            SEEDBOX_DOMAIN=$answer
            SEEDBOX_LETSENCRYPT=auto
            return 0
        fi
        say "  Let's Encrypt will not be able to issue a certificate for this name."
        say '  (after a DNS change, allow a few minutes to a few hours)'
        say '  R) Try again    C) Continue with a self-signed certificate'
        say '  B) Back, nothing is changed'
        ask choice 'Your choice' "R"
        case ${choice,,} in
            c)
                SEEDBOX_DOMAIN=$answer
                SEEDBOX_LETSENCRYPT=no
                return 0
                ;;
            b | q) return 1 ;;
        esac
    done
}

# --- Applying (idempotent) -----------------------------------------------------------

seedbox_apply_user() {
    local current
    if ! id "$SEEDBOX_USER" &>/dev/null; then
        run "$(t 'Creating the user %s' "$SEEDBOX_USER")" useradd --no-create-home --home-dir / \
            --shell /usr/sbin/nologin --user-group --groups "$TRANSMISSION_USER" \
            --comment "seedtunnel seedbox" "$SEEDBOX_USER"
    fi
    if [[ " $(id -nG "$SEEDBOX_USER") " != *" $TRANSMISSION_USER "* ]]; then
        usermod -aG "$TRANSMISSION_USER" "$SEEDBOX_USER"
    fi
    if [[ -n $SEEDBOX_NEW_PASSWORD ]]; then
        seedbox_hash_password
    elif [[ -z $SEEDBOX_HASH_SYSTEM || -z $SEEDBOX_HASH_WEB || -z $SEEDBOX_HASH_TRANSMISSION ]]; then
        die 'No known password for %s: set one with  seedtunnel seedbox password' "$SEEDBOX_USER"
    else
        current=$(getent shadow "$SEEDBOX_USER" | cut -d: -f2)
        if [[ $current != "$SEEDBOX_HASH_SYSTEM" ]]; then
            printf '%s:%s\n' "$SEEDBOX_USER" "$SEEDBOX_HASH_SYSTEM" | chpasswd -e
        fi
    fi
}

# --- AppArmor (Ubuntu 26.04) --------------------------------------------------------
# Ubuntu 26.04 confines transmission-daemon with an AppArmor profile that only
# lets it write to /var/lib/transmission-daemon/downloads: in the data folder
# of the seedbox, every download failed (« Permission denied »), although its
# permissions were right. The profile includes local/transmission-daemon for
# the additions of the site: seedtunnel writes there the data folder, and only
# it, then reloads the profile. Without this profile (Debian, Ubuntu 24.04):
# nothing. AppArmor itself is left as it is.
TRANSMISSION_APPARMOR_PROFILE="/etc/apparmor.d/transmission"
TRANSMISSION_APPARMOR_LOCAL="/etc/apparmor.d/local/transmission-daemon"
APPARMOR_ENABLED_FILE="/sys/module/apparmor/parameters/enabled"

transmission_apparmor_confined() {
    [[ -f $TRANSMISSION_APPARMOR_PROFILE ]] && grep -q 'local/transmission-daemon' "$TRANSMISSION_APPARMOR_PROFILE" 2>/dev/null
}

# The rules for the data folder (quoted: a path may hold a space)
transmission_apparmor_generate() {
    local dir
    dir=$(realpath -m "$SEEDBOX_DATA_DIR")
    printf '%s\n' '# Written by seedtunnel: Transmission may use the data folder of the seedbox' \
        '# (the profile of the system only allows /var/lib/transmission-daemon/downloads).' \
        "\"$dir/\" r," "\"$dir/**\" rwk,"
}

# The profile loaded again with its additions; it applies to Transmission
# right away, even running. A failure is said, never fatal: the diagnostics
# point out what Transmission is refused.
transmission_apparmor_reload() {
    local description
    command -v apparmor_parser &>/dev/null || return 0
    [[ $(cat "$APPARMOR_ENABLED_FILE" 2>/dev/null) == Y ]] || return 0
    description=$(t 'Reloading the AppArmor profile of Transmission')
    printf '  %s… ' "$description"
    log_print '\n=== %(%F %T)T · %s\n$ apparmor_parser -r %s\n' -1 "$description" "$TRANSMISSION_APPARMOR_PROFILE"
    if apparmor_parser -r "$TRANSMISSION_APPARMOR_PROFILE" >>"$APP_LOG" 2>&1; then
        printf '%s%s%s\n' "$C_GREEN" "$(t 'ok')" "$C_RESET"
    else
        printf '%s%s%s\n' "$C_RED" "$(t 'failed')" "$C_RESET"
        warn 'The AppArmor profile of Transmission could not be reloaded (details in %s): downloads to %s may fail until the next restart of the server.' \
            "$APP_LOG" "$SEEDBOX_DATA_DIR"
    fi
}

seedbox_apply_apparmor() {
    transmission_apparmor_confined || return 0
    install -d -m 755 "${TRANSMISSION_APPARMOR_LOCAL%/*}"
    if write_if_changed "$TRANSMISSION_APPARMOR_LOCAL" 644 root:root transmission_apparmor_generate; then
        transmission_apparmor_reload
    fi
}

# On removal: our rules only (a file of the administrator stays)
seedbox_remove_apparmor() {
    grep -q '^# Written by seedtunnel' "$TRANSMISSION_APPARMOR_LOCAL" 2>/dev/null || return 0
    rm -f "$TRANSMISSION_APPARMOR_LOCAL"
    if transmission_apparmor_confined; then transmission_apparmor_reload; fi
}

seedbox_apply_dirs() {
    install -d -m 755 -o root -g root "$SEEDBOX_DATA_DIR"
    # setgid (the 2 of 2775): everything created inside belongs to the group of
    # Transmission, so the SFTP user can read and delete the files.
    install -d -m 2775 -o "$TRANSMISSION_USER" -g "$TRANSMISSION_USER" \
        "$SEEDBOX_DATA_DIR/complete" "$SEEDBOX_DATA_DIR/incomplete" "$SEEDBOX_DATA_DIR/watch"
    install -d -m 700 -o "$SEEDBOX_USER" -g "$SEEDBOX_USER" "$SEEDBOX_DATA_DIR/documents"
}

# The hash of the password goes through the environment, never as an argument:
# the arguments of every command can be read by every account (ps)
transmission_desired_settings() {
    SEEDTUNNEL_HASH=$SEEDBOX_HASH_TRANSMISSION jq -n --arg dl "$SEEDBOX_DATA_DIR/complete" \
        --arg inc "$SEEDBOX_DATA_DIR/incomplete" --arg watch "$SEEDBOX_DATA_DIR/watch" --arg user "$SEEDBOX_USER" \
        --argjson rpcport "$TRANSMISSION_RPC_PORT" --argjson peerport "$TORRENT_PORT" \
        "\$ENV.SEEDTUNNEL_HASH as \$hash | $TRANSMISSION_SETTINGS_FILTER"
}

# Are the wanted settings already in place? (« umask » is ignored: Transmission
# writes it back in its own way depending on the version)
transmission_settings_uptodate() {
    [[ -s $1 ]] || return 1
    jq -e --slurpfile d <(printf '%s' "$2") '. as $c | $d[0] | del(.umask) | to_entries | all(.value == $c[.key])' "$1" &>/dev/null
}

# Names of the wanted settings that differ (for the log: never their values)
transmission_settings_differences() {
    jq -r --slurpfile d <(printf '%s' "$2") '. as $c | $d[0] | del(.umask) | to_entries[] | select(.value != $c[.key]) | .key' "$1" 2>/dev/null \
        | paste -sd' ' - || true
}

# systemd hardening: if Transmission were compromised, it could only write to
# its own folders and to the download folder.
transmission_generate_dropin() {
    local home=yes
    case $SEEDBOX_DATA_DIR in
        /home/* | /root/* | /run/user/*) home=no ;;
    esac
    cat <<EOF
# Written by seedtunnel — Transmission locked down by systemd
[Unit]
# downloads on a disk of their own: never on the system disk if it is missing
RequiresMountsFor=$SEEDBOX_DATA_DIR

[Service]
# not started on an almost full disk (« + »: this check runs as root)
ExecStartPre=+$APP_DIR/seedtunnel.sh diskguard-prestart
UMask=0002
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=-/var/lib/transmission-daemon -/etc/transmission-daemon -$SEEDBOX_DATA_DIR
ProtectHome=$home
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
EOF
}

seedbox_apply_transmission() {
    local settings desired changes restart=0 stopped=0 tmp
    settings=$(transmission_settings_file) || exit 1
    # a restore: its settings and torrents first, Transmission stopped
    if [[ -n $TRANSMISSION_RESTORE_FROM ]]; then
        run 'Stopping Transmission' systemctl stop transmission-daemon
        stopped=1
        restore_transmission_state "$TRANSMISSION_RESTORE_FROM"
        TRANSMISSION_RESTORE_FROM=""
        restart=1
    fi
    desired=$(transmission_desired_settings)
    # Transmission 4.1 and later (Ubuntu 26.04): « preferred_transports » wins
    # over « utp-enabled », and without it uTP is on: TCP only there too, even
    # when the file does not have it yet (settings of an older Transmission,
    # brought back by a restore)
    if jq -e 'has("preferred_transports")' "$settings" &>/dev/null || transmission_knows_transports; then
        desired=$(jq -c '. + {"preferred_transports": ["tcp"]}' <<<"$desired")
    fi
    install -d -m 755 "${TRANSMISSION_DROPIN%/*}"
    if write_if_changed "$TRANSMISSION_DROPIN" 644 root:root transmission_generate_dropin; then
        run 'Reloading systemd' systemctl daemon-reload
        restart=1
    fi
    if ! transmission_settings_uptodate "$settings" "$desired"; then
        changes=$(transmission_settings_differences "$settings" "$desired")
        # Transmission writes its settings back when it stops: change them while stopped
        if ((!stopped)); then run 'Stopping Transmission' systemctl stop transmission-daemon; fi
        # under the title of the step (never the values: one of them is a password hash)
        if ((stopped)); then log_title 'Changing the settings of Transmission'; fi
        log_print 'Transmission: settings to change: %s\n' "$changes"
        # prepared in a folder of root, checked, then written by the account of
        # Transmission ($settings is the real file: the link of Debian points
        # to it, and still does)
        tmp=$(mktemp "$APP_STATE_DIR/.transmission-settings.XXXXXX")
        if ! { if [[ -s $settings ]]; then
            jq --slurpfile d <(printf '%s' "$desired") '. + $d[0]' "$settings"
        else
            printf '%s\n' "$desired"
        fi; } >"$tmp" 2>>"$APP_LOG" || ! jq empty "$tmp" 2>/dev/null || ! transmission_settings_write "$settings" "$tmp" 2>>"$APP_LOG"; then
            rm -f "$tmp"
            systemctl start transmission-daemon >>"$APP_LOG" 2>&1 || true
            die 'Cannot write the settings of Transmission %s (invalid JSON or disk full?). The previous ones were kept.' "$settings"
        fi
        rm -f "$tmp"
        restart=1
    fi
    systemctl enable --quiet transmission-daemon 2>/dev/null || true
    # stopped on purpose because the disk is almost full: left alone
    if diskguard_stopped; then return 0; fi
    if ((restart)) || ! systemctl is-active --quiet transmission-daemon; then
        run 'Starting Transmission' systemctl restart transmission-daemon
    fi
}

seedbox_apply_htpasswd() {
    write_if_changed "$NGINX_HTPASSWD" 640 root:www-data \
        printf '%s:%s\n' "$SEEDBOX_USER" "$SEEDBOX_HASH_WEB" || true
}

# Self-signed fallback certificate, created again only if it no longer matches
seedbox_selfsigned_ensure() {
    local san="DNS:$SEEDBOX_DOMAIN" check=""
    local -a req
    if is_ipv4 "$SEEDBOX_DOMAIN"; then san="IP:$SEEDBOX_DOMAIN"; fi
    install -d -m 700 "$SEEDBOX_SSL_DIR"
    if [[ -s $SEEDBOX_SSL_DIR/selfsigned.crt && -s $SEEDBOX_SSL_DIR/selfsigned.key ]]; then
        if is_ipv4 "$SEEDBOX_DOMAIN"; then
            check=$(openssl x509 -in "$SEEDBOX_SSL_DIR/selfsigned.crt" -noout -checkip "$SEEDBOX_DOMAIN" 2>/dev/null || true)
        else
            check=$(openssl x509 -in "$SEEDBOX_SSL_DIR/selfsigned.crt" -noout -checkhost "$SEEDBOX_DOMAIN" 2>/dev/null || true)
        fi
        [[ $check == *"does match"* ]] && return 0
    fi
    req=(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650
        -subj "/CN=$SEEDBOX_DOMAIN" -addext "subjectAltName=$san"
        -keyout "$SEEDBOX_SSL_DIR/selfsigned.key" -out "$SEEDBOX_SSL_DIR/selfsigned.crt")
    # a fallback when Let's Encrypt fails for a domain name; with an IP
    # address, the certificate that was chosen
    if is_ipv4 "$SEEDBOX_DOMAIN"; then
        run 'Creating a self-signed certificate' "${req[@]}"
    else
        run 'Creating a self-signed certificate (fallback)' "${req[@]}"
    fi
}

# SHA-256 fingerprint of the self-signed certificate, as browsers show it
seedbox_selfsigned_fingerprint() {
    openssl x509 -in "$SEEDBOX_SSL_DIR/selfsigned.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true
}

# Is the existing Let's Encrypt certificate for this name?
letsencrypt_matches_domain() {
    local check
    [[ -e $LETSENCRYPT_DIR/cert.pem ]] || return 1
    check=$(openssl x509 -in "$LETSENCRYPT_DIR/cert.pem" -noout -checkhost "$SEEDBOX_DOMAIN" 2>/dev/null || true)
    [[ $check == *"does match"* ]]
}

# … and usable for the requested kind (production | staging), valid for 1 more day?
letsencrypt_usable() {
    local issuer
    letsencrypt_matches_domain || return 1
    openssl x509 -in "$LETSENCRYPT_DIR/cert.pem" -noout -checkend 86400 &>/dev/null || return 1
    issuer=$(openssl x509 -in "$LETSENCRYPT_DIR/cert.pem" -noout -issuer 2>/dev/null || true)
    if [[ $issuer == *STAGING* ]]; then [[ $1 == staging ]]; else [[ $1 == production ]]; fi
}

# Expiry date of the Let's Encrypt certificate (YYYY-MM-DD), empty if none
letsencrypt_expiry_date() {
    local end
    end=$(openssl x509 -in "$LETSENCRYPT_DIR/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    [[ -n $end ]] || return 0
    date -d "$end" +%F 2>/dev/null || true
}

seedbox_certificate_mode() {
    if [[ $SEEDBOX_LETSENCRYPT_SERVER == staging ]]; then printf staging; else printf letsencrypt; fi
}

# The command that asks for the certificate again: for the seedbox, or for
# the site of the links of the VPN (see links_run in share.sh)
letsencrypt_retry_command() {
    if seedbox_installed; then
        printf 'seedtunnel seedbox domain %s' "$SEEDBOX_DOMAIN"
    else
        printf 'seedtunnel vpn links on'
    fi
}

# Requests the Let's Encrypt certificate. Status 1 if it fails.
letsencrypt_request() {
    local label=""
    local -a extra=()
    install -d -m 755 "$LETSENCRYPT_WEBROOT"
    # Existing certificate for another name or another server: start over
    if [[ -e $LETSENCRYPT_DIR/cert.pem ]] && ! letsencrypt_usable "$SEEDBOX_LETSENCRYPT_SERVER"; then
        certbot delete --cert-name "$LETSENCRYPT_CERT_NAME" --non-interactive >>"$APP_LOG" 2>&1 || true
    fi
    if [[ $SEEDBOX_LETSENCRYPT_SERVER == staging ]]; then
        extra=(--test-cert)
        label=" $(t '(test server)')"
    fi
    printf '  %s… ' "$(t "Requesting the Let's Encrypt certificate%s for %s" "$label" "$SEEDBOX_DOMAIN")"
    log_title "Let's Encrypt certificate for %s" "$SEEDBOX_DOMAIN"
    if certbot certonly --webroot -w "$LETSENCRYPT_WEBROOT" --cert-name "$LETSENCRYPT_CERT_NAME" -d "$SEEDBOX_DOMAIN" \
        --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring \
        --deploy-hook "systemctl reload nginx" "${extra[@]}" >>"$APP_LOG" 2>&1; then
        printf '%s%s%s\n' "$C_GREEN" "$(t 'ok')" "$C_RESET"
        return 0
    fi
    printf '%s%s%s\n' "$C_RED" "$(t 'failed')" "$C_RESET"
    return 1
}

# Does the Transmission installed know « preferred_transports »? Since
# 4.1.0-beta.4 (in its code: libtransmission/session.h). An older one would
# drop it from its settings, and it would be added again at every run.
transmission_knows_transports() {
    local version
    version=$(dpkg-query -W -f='${Version}' transmission-daemon 2>/dev/null || true)
    [[ -n $version ]] && dpkg --compare-versions "$version" ge 4.1.0~beta4
}

# Does the Transmission installed take magnet links (NAME.magnet) from its
# watch folder? Since 4.0.0 (« add magnet file support to watchdir »).
transmission_reads_magnets() {
    local version
    version=$(dpkg-query -W -f='${Version}' transmission-daemon 2>/dev/null || true)
    [[ -n $version ]] && dpkg --compare-versions "$version" ge 4.0.0~
}

# The style sheet of seedtunnel for the version of Transmission installed:
# Transmission 3 (Debian 12) and 4 (Debian 13…) have different pages. Nothing
# for another version, or without the file: the page stays as it comes.
transmission_web_theme_file() {
    local version file=""
    version=$(dpkg-query -W -f='${Version}' transmission-daemon 2>/dev/null || true)
    version=${version#*:}
    version=${version%%.*}
    if [[ $version == 3 ]]; then
        file="web/transmission3-theme.css"
    elif [[ $version =~ ^[0-9]+$ ]] && ((version >= 4)); then
        file="web/transmission-theme.css"
    fi
    if [[ -n $file && -r $APP_DIR/$file ]]; then printf '%s' "$file"; fi
}

# nginx directives for the style (empty without it). $1: « file » for the
# location of the style sheet, « page » for what goes in /transmission/.
nginx_generate_theme() {
    local file url
    file=$(transmission_web_theme_file)
    [[ -n $file ]] || return 0
    url="/seedtunnel/${file#web/}"
    if [[ $1 == file ]]; then
        cat <<EOF

    # Style of seedtunnel for the web interface ($file)
    location = $url {
        alias $APP_DIR/$file;
        default_type text/css;
    }
EOF
    else
        cat <<EOF

        # the style of seedtunnel, added to the page of Transmission as it
        # passes (the page must come uncompressed for that); Transmission
        # itself is not changed
        proxy_set_header Accept-Encoding "";
        sub_filter '</head>' '<link href="$url" rel="stylesheet" /></head>';
        sub_filter '<title>Transmission Web Interface</title>' '<title>SeedTunnel · Transmission</title>';
        sub_filter_once on;
EOF
    fi
}

# TLS lines of the HTTPS server (seedbox, or site of the links): the
# certificate chosen (SEEDBOX_CERTIFICATE) and the settings
nginx_generate_tls() {
    local crt key
    if [[ $SEEDBOX_CERTIFICATE == selfsigned ]]; then
        crt="$SEEDBOX_SSL_DIR/selfsigned.crt"
        key="$SEEDBOX_SSL_DIR/selfsigned.key"
    else
        crt="$LETSENCRYPT_DIR/fullchain.pem"
        key="$LETSENCRYPT_DIR/privkey.pem"
    fi
    cat <<EOF
    ssl_certificate     $crt;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:seedtunnel:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
EOF
}

# HSTS header, starting with a new line: only with a real certificate,
# otherwise the browser would then refuse to let the user accept the security
# warning
nginx_generate_hsts() {
    if [[ $SEEDBOX_CERTIFICATE == letsencrypt ]]; then
        printf '\n    add_header Strict-Transport-Security "max-age=31536000" always;'
    fi
}

nginx_generate_site() {
    local hsts ipv6_80="" ipv6_443=""
    hsts=$(nginx_generate_hsts)
    if [[ -e /proc/net/if_inet6 ]]; then
        ipv6_80=$'\n    listen [::]:80;'
        ipv6_443=$'\n    listen [::]:443 ssl;'
    fi
    cat <<EOF
# Written by seedtunnel — use the menu rather than editing this file.

$(share_generate_nginx_http)

server {
    listen 80;$ipv6_80
    server_name $SEEDBOX_DOMAIN;
    # a link typed with http:// must not leave its token in the log either
    access_log /var/log/nginx/access.log seedtunnel_share;

    # Let's Encrypt validation and renewal
    location ^~ /.well-known/acme-challenge/ {
        root $LETSENCRYPT_WEBROOT;
        default_type text/plain;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;$ipv6_443
    server_name $SEEDBOX_DOMAIN;

$(nginx_generate_tls)

    server_tokens off;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;$hsts

    # the name sent with the request for the password, to anyone (robots
    # included): it tells nothing of what is behind
    auth_basic "Restricted";
    auth_basic_user_file $NGINX_HTPASSWD;$(nginx_generate_denied_page)$(share_generate_nothing_error)$(nginx_generate_stopped_page)

    # Adding .torrent files from the web interface
    client_max_body_size 32m;
$(share_generate_nginx "${hsts//$'\n    '/$'\n        '}")

    # Home page: the password first, then the web interface. A « return » here
    # would answer before nginx asks for the password (it runs earlier), and
    # tell anyone that Transmission is behind: try_files runs after it.
    location = / {
        try_files /.seedtunnel-no-such-file @seedbox_home;
    }
    location @seedbox_home {
        return 302 /transmission/web/;
    }$(nginx_generate_theme file)
    location /transmission/ {
        proxy_pass http://127.0.0.1:$TRANSMISSION_RPC_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300s;$(nginx_generate_theme page)
    }

    # Any other address: the password first (try_files runs after it, as for
    # the home page), then a 404 with the page « nothing here » instead of the
    # one of nginx. Nothing of the default folder of nginx is served.
    location / {
        try_files /.seedtunnel-no-such-file =404;
    }
}
EOF
}

NGINX_DENIED_PAGE="web/unauthorized.html"

# The page shown when the password is refused or « Cancel » is clicked, in the
# colors of seedtunnel but without its name: nothing tells what is behind. The
# answer stays a 401 with the header that makes the browser ask for the
# password. Only if the page is there: without it, nginx would answer 404 and
# never ask for the password again. A location with an error_page of its own
# would not use this one (only /share/ has one, and asks for no password).
nginx_generate_denied_page() {
    [[ -r $APP_DIR/$NGINX_DENIED_PAGE ]] || return 0
    cat <<EOF

    error_page 401 /seedtunnel/denied.html;
    location = /seedtunnel/denied.html {
        auth_basic off;
        internal;
        alias $APP_DIR/$NGINX_DENIED_PAGE;
        default_type text/html;
    }
EOF
}

NGINX_STOPPED_PAGE="web/transmission-stopped.html"

# The page shown instead of the « 502 Bad Gateway » of nginx when Transmission
# does not answer: stopped because the disk is almost full (diskguard), or
# starting again. Set for the whole site, as the page of the refused password:
# an error_page in /transmission/ would make that one forgotten there. Only
# reached through /transmission/, so after the password; the answer stays a
# 502 (or 504). Only if the page is there.
nginx_generate_stopped_page() {
    [[ -r $APP_DIR/$NGINX_STOPPED_PAGE ]] || return 0
    cat <<EOF

    error_page 502 504 /seedtunnel/transmission-stopped.html;
    location = /seedtunnel/transmission-stopped.html {
        auth_basic off;
        internal;
        alias $APP_DIR/$NGINX_STOPPED_PAGE;
        default_type text/html;
    }
EOF
}

# The site « default » of nginx, as the package installs it: the link to the
# file of the package, never changed (same fingerprint as in the package)
nginx_default_site_untouched() {
    local package md5
    [[ -L $NGINX_DEFAULT_SITE && $(readlink -f "$NGINX_DEFAULT_SITE") == "$(readlink -f "$NGINX_DEFAULT_SOURCE")" ]] || return 1
    package=$(dpkg-query -S "$NGINX_DEFAULT_SOURCE" 2>/dev/null | cut -d: -f1 | head -n 1)
    [[ -n $package ]] || return 1
    md5=$(dpkg-query -W -f='${Conffiles}\n' "$package" 2>/dev/null | awk -v file="$NGINX_DEFAULT_SOURCE" '$1 == file { print $2 }')
    [[ -n $md5 && $(md5sum <"$NGINX_DEFAULT_SOURCE") == "$md5 "* ]]
}

# Turns off the site « default » of nginx only if it is the one of the
# package: a site of the administrator stays (seedtunnel does not need it to
# be off: its own site answers to its name). Said once, not at each apply.
nginx_default_site_off() {
    local note="$APP_STATE_DIR/nginx-default-kept"
    if [[ ! -e $NGINX_DEFAULT_SITE && ! -L $NGINX_DEFAULT_SITE ]]; then
        rm -f "$note"
    elif nginx_default_site_untouched; then
        rm -f "$NGINX_DEFAULT_SITE" "$note"
        pending_set nginx
    elif [[ ! -e $note ]]; then
        warn 'The site « default » of nginx was changed: seedtunnel leaves it on (%s).' "$NGINX_DEFAULT_SITE"
        : >"$note"
    fi
}

# The site of the seedbox; or, through links_run (share.sh), the site of the
# links of the VPN: same file, same certificates
seedbox_apply_nginx() {
    if write_if_changed "$NGINX_SITE" 644 root:root "${NGINX_SITE_GENERATOR:-nginx_generate_site}"; then pending_set nginx; fi
    if [[ ! -L $NGINX_SITE_LINK ]]; then
        ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
        pending_set nginx
    fi
    nginx_default_site_off
    if pending nginx || ! systemctl is-active --quiet nginx; then
        run 'Checking the nginx configuration' nginx -t
        run 'Reloading nginx' systemctl reload-or-restart nginx
        pending_clear nginx
    fi
    # also at boot (it may have been turned off there)
    unit_ensure_on "$(t 'Enabling %s at boot' nginx)" nginx
}

# Chooses the certificate served: Let's Encrypt if available or obtained,
# otherwise the self-signed one.
seedbox_apply_https() {
    local want=0 ip
    seedbox_selfsigned_ensure
    if is_ipv4 "$SEEDBOX_DOMAIN" || [[ $SEEDBOX_LETSENCRYPT == no ]]; then
        SEEDBOX_CERTIFICATE=selfsigned
    elif letsencrypt_usable "$SEEDBOX_LETSENCRYPT_SERVER"; then
        # certificate already in place (run again, restore): nothing to request
        SEEDBOX_CERTIFICATE=$(seedbox_certificate_mode)
    else
        if [[ $SEEDBOX_LETSENCRYPT == yes ]]; then
            want=1
        else
            ip=$(public_ipv4)
            if dns_points_here "$SEEDBOX_DOMAIN" "$ip"; then
                want=1
            else
                warn '"%s" does not point to this server (%s): self-signed certificate.' "$SEEDBOX_DOMAIN" "$ip"
            fi
        fi
        if ((want)); then
            # nginx must already answer on port 80 for the validation
            if [[ $SEEDBOX_CERTIFICATE != selfsigned ]] && ! letsencrypt_matches_domain; then SEEDBOX_CERTIFICATE=selfsigned; fi
            seedbox_apply_nginx
            if letsencrypt_request; then
                SEEDBOX_CERTIFICATE=$(seedbox_certificate_mode)
                ok "Let's Encrypt certificate installed, renewed automatically."
            elif letsencrypt_usable "$SEEDBOX_LETSENCRYPT_SERVER"; then
                SEEDBOX_CERTIFICATE=$(seedbox_certificate_mode)
                warn "Let's Encrypt did not answer, the existing certificate (still valid) is kept."
            else
                SEEDBOX_CERTIFICATE=selfsigned
                warn "Let's Encrypt did not issue a certificate: the self-signed one stays in place."
                text letsencrypt_failed_help
            fi
        else
            SEEDBOX_CERTIFICATE=selfsigned
        fi
    fi
    seedbox_apply_nginx
    # automatic renewal (installed with the certbot package), at boot too
    if [[ $SEEDBOX_CERTIFICATE != selfsigned ]]; then
        unit_ensure_on 'Enabling automatic renewal' certbot.timer
    fi
}

sftp_has_keys() { [[ -s $SFTP_KEYS_DIR/$SEEDBOX_USER ]] && grep -q '^ssh-\|^ecdsa-\|^sk-' "$SFTP_KEYS_DIR/$SEEDBOX_USER"; }

# The .ssh folder of the personal folder on Windows, where the WinSCP profile
# looks for the key made by seedtunnel (as a value: printf would read « \U »)
windows_ssh_folder() { printf 'C:\\Users\\%s\\.ssh' "$(t 'YOUR-NAME')"; }

# A key made by seedtunnel (sftp_key_generate) among those of the account: its
# private part is then the file seedbox-USER.ppk on the computer of the user
sftp_has_seedtunnel_key() {
    [[ -s $SFTP_KEYS_DIR/$SEEDBOX_USER ]] && grep -q " seedtunnel-$SEEDBOX_USER-[0-9]" "$SFTP_KEYS_DIR/$SEEDBOX_USER"
}

# Effective SSH settings of the seedbox account connecting from the address
# $1, as sshd applies them
seedbox_sshd_settings() { sshd_settings -C "user=$SEEDBOX_USER,host=$1,addr=$1"; }

# Are all the restrictions written for the account (sshd_generate_seedbox_conf)
# in force, wherever it connects from? From the server itself, through the
# VPN, from the Internet: a Match Address block could treat them differently.
# The way to log in too: « keys only » must leave no password, not even
# through keyboard-interactive, and the keys must be the ones of seedtunnel.
seedbox_sftp_rule_applies() {
    local address settings line
    for address in 127.0.0.1 "$VPN_SUBNET.2" 203.0.113.1; do
        settings=$(seedbox_sshd_settings "$address")
        grep -qxF "chrootdirectory $SEEDBOX_DATA_DIR" <<<"$settings" || return 1
        grep -q '^forcecommand internal-sftp' <<<"$settings" || return 1
        for line in 'permittty no' 'allowtcpforwarding no' 'allowagentforwarding no' \
            'allowstreamlocalforwarding no' 'x11forwarding no' 'permittunnel no' \
            "passwordauthentication $SEEDBOX_SFTP_PASSWORD" 'kbdinteractiveauthentication no' \
            'pubkeyauthentication yes'; do
            grep -qxF "$line" <<<"$settings" || return 1
        done
        grep -qxF -e "authorizedkeysfile $SFTP_KEYS_DIR/%u" -e "authorizedkeysfile $SFTP_KEYS_DIR/$SEEDBOX_USER" \
            <<<"$settings" || return 1
    done
}

# A suspended account cannot log in at all, by password or by key (expired
# account), and its sessions are closed: used while its SFTP restrictions are
# not in force. Expiry « 1 » (2 January 1970) marks a suspension by seedtunnel.
# Checked, not assumed: fails if the account is not expired afterwards, or
# still has processes.
seedbox_user_suspend() {
    local user=${1:-$SEEDBOX_USER} i
    id "$user" &>/dev/null || return 0
    usermod --expiredate 1 "$user" >>"$APP_LOG" 2>&1 || true
    [[ $(getent shadow "$user" 2>/dev/null | cut -d: -f8 || true) == 1 ]] || return 1
    for i in {1..20}; do
        pkill -KILL -u "$user" >>"$APP_LOG" 2>&1 || true
        if ! pgrep -u "$user" >/dev/null 2>&1; then return 0; fi
        sleep 0.2
    done
    return 1
}

# Back to normal, if it was suspended by seedtunnel. Checked, not assumed:
# status 1 if the account is still expired afterwards.
seedbox_user_resume() {
    local user=${1:-$SEEDBOX_USER}
    if [[ $(getent shadow "$user" 2>/dev/null | cut -d: -f8 || true) == 1 ]]; then
        usermod --expiredate '' "$user" >>"$APP_LOG" 2>&1 || true
        [[ $(getent shadow "$user" 2>/dev/null | cut -d: -f8 || true) != 1 ]] || return 1
    fi
}

# Renames the account, its group and its SSH keys, suspended meanwhile (its
# SFTP rule is written for the old name). If a step fails, the steps already
# done are undone: the account keeps its old name, never half renamed.
seedbox_rename_account() {
    local old=$1 new=$2 group=0
    if ! seedbox_user_suspend "$old"; then
        seedbox_user_resume "$old" || true
        die 'Cannot suspend %s before renaming it (details in %s): nothing was changed.' "$old" "$APP_LOG"
    fi
    usermod --login "$new" "$old" >>"$APP_LOG" 2>&1 || seedbox_rename_undo "$old" "$new" 0 0
    if getent group "$old" >/dev/null; then
        groupmod --new-name "$new" "$old" >>"$APP_LOG" 2>&1 || seedbox_rename_undo "$old" "$new" 1 0
        group=1
    fi
    if [[ -e $SFTP_KEYS_DIR/$old ]]; then
        mv -f "$SFTP_KEYS_DIR/$old" "$SFTP_KEYS_DIR/$new" || seedbox_rename_undo "$old" "$new" 1 "$group"
    fi
    # in the log (a restore, new credentials): the report hides both names
    log_title 'SFTP account %s renamed to %s' "$old" "$new"
    ok 'Account %s renamed to %s' "$old" "$new"
}

# seedbox_rename_undo OLD NEW USER_RENAMED GROUP_RENAMED — a step of the
# rename failed: the old names come back, then stop
seedbox_rename_undo() {
    local old=$1 new=$2
    if (($4)) && ! groupmod --new-name "$old" "$new" >>"$APP_LOG" 2>&1; then
        # the account stays suspended: half renamed, it must not be used
        if (($3)); then usermod --login "$old" "$new" >>"$APP_LOG" 2>&1 || true; fi
        die 'Renaming %s to %s failed, and so did putting the old name of the group back (details in %s). The account stays suspended. By hand:  groupmod --new-name %s %s ; usermod --login %s %s ; seedtunnel apply' "$old" "$new" "$APP_LOG" "$old" "$new" "$old" "$new"
    fi
    if (($3)) && ! usermod --login "$old" "$new" >>"$APP_LOG" 2>&1; then
        die 'Renaming %s to %s failed, and so did putting the old name back (details in %s). By hand:  usermod --login %s %s' "$old" "$new" "$APP_LOG" "$old" "$new"
    fi
    seedbox_user_resume "$old" || true
    die 'Renaming %s to %s failed (details in %s): the account keeps its name %s.' "$old" "$new" "$APP_LOG" "$old"
}

sshd_generate_seedbox_conf() {
    cat <<EOF
# Written by seedtunnel — SFTP access to the seedbox, locked in $SEEDBOX_DATA_DIR
Match User $SEEDBOX_USER
    ChrootDirectory $SEEDBOX_DATA_DIR
    ForceCommand internal-sftp -u 0002
    AuthorizedKeysFile $SFTP_KEYS_DIR/%u
    PasswordAuthentication $SEEDBOX_SFTP_PASSWORD
    KbdInteractiveAuthentication no
    PermitTTY no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
}

seedbox_apply_sftp() {
    local settings
    install -d -m 755 "$SFTP_KEYS_DIR"
    if [[ ! -e $SFTP_KEYS_DIR/$SEEDBOX_USER ]]; then install -m 644 /dev/null "$SFTP_KEYS_DIR/$SEEDBOX_USER"; fi
    if [[ $SEEDBOX_SFTP_PASSWORD == no ]] && ! sftp_has_keys; then
        warn 'No SSH key saved: the SFTP password stays allowed.'
        SEEDBOX_SFTP_PASSWORD=yes
    fi
    if [[ -e $SSHD_SEEDBOX_CONF ]]; then cp -p "$SSHD_SEEDBOX_CONF" "$SSHD_SEEDBOX_CONF.previous"; fi
    if write_if_changed "$SSHD_SEEDBOX_CONF" 644 root:root sshd_generate_seedbox_conf; then pending_set ssh; fi
    if pending ssh; then
        # SSH is only reloaded if the configuration is valid: no risk of being
        # locked out. Otherwise, back to the previous version.
        sshd_runtime_dir
        if ! sshd -t >>"$APP_LOG" 2>&1; then
            if [[ -e $SSHD_SEEDBOX_CONF.previous ]]; then
                mv -f "$SSHD_SEEDBOX_CONF.previous" "$SSHD_SEEDBOX_CONF"
                # put back by seedtunnel, not changed by hand
                written_remember "$SSHD_SEEDBOX_CONF"
            else
                rm -f "$SSHD_SEEDBOX_CONF"
            fi
            pending_clear ssh
            die 'sshd refuses the generated configuration (details in %s). SSH was not changed.' "$APP_LOG"
        fi
        run 'Reloading SSH' systemctl try-reload-or-restart ssh.service
        pending_clear ssh
    fi
    rm -f "$SSHD_SEEDBOX_CONF.previous"

    # Do the restrictions really apply to the account (Include present, no
    # Match block before ours…)? If not, the account is suspended: no access
    # at all rather than an account without its restrictions.
    if seedbox_sftp_rule_applies; then
        seedbox_user_resume || die 'The account %s could not be reactivated (details in %s): it stays suspended. By hand:  usermod --expiredate "" %s' "$SEEDBOX_USER" "$APP_LOG" "$SEEDBOX_USER"
    elif seedbox_user_suspend; then
        die 'The SFTP restrictions (chroot, SFTP only, no tunnel) do not apply to %s: the account is suspended. /etc/ssh/sshd_config must contain "Include /etc/ssh/sshd_config.d/*.conf" before any Match block; then run:  seedtunnel apply' "$SEEDBOX_USER"
    else
        die 'The SFTP restrictions (chroot, SFTP only, no tunnel) do not apply to %s, and the account could not be suspended (details in %s). Suspend it by hand:  usermod --expiredate 1 %s && pkill -KILL -u %s' "$SEEDBOX_USER" "$APP_LOG" "$SEEDBOX_USER" "$SEEDBOX_USER"
    fi
    settings=$(seedbox_sshd_settings 127.0.0.1)
    if [[ $settings == *$'\nallowusers '* || $settings == *$'\nallowgroups '* ]]; then
        warn 'Your SSH uses AllowUsers/AllowGroups: add %s to it so that it can connect.' "$SEEDBOX_USER"
    fi
}

fail2ban_generate_main() {
    # explicit log file: the « recidive » jail reads it
    cat <<'EOF'
# Written by seedtunnel
[DEFAULT]
logtarget = /var/log/fail2ban.log

[Definition]
logtarget = /var/log/fail2ban.log
EOF
}

fail2ban_generate_jail() {
    cat <<'EOF'
# Written by seedtunnel — protection against password guessing
[DEFAULT]
# The machine itself and the VPN clients are never banned
ignoreip  = 127.0.0.1/8 ::1 10.8.0.0/24
bantime   = 1h
findtime  = 10m
maxretry  = 5
banaction = nftables-multiport
banaction_allports = nftables[type=allports]

# SSH and SFTP: 5 failures in 10 min → banned 1 h from every port, which stays
# effective even when SSH does not listen on port 22
# (Debian 12+ has no /var/log/auth.log any more: the systemd journal is read)
[sshd]
enabled   = true
backend   = systemd
mode      = aggressive
banaction = %(banaction_allports)s

# Password of the web interface
[nginx-http-auth]
enabled = true
backend = auto
port    = http,https
logpath = /var/log/nginx/error.log

# Repeat offenders: banned 3 times in 24 h → banned 1 week from every port
[recidive]
enabled   = true
backend   = auto
logpath   = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime   = 1w
findtime  = 1d
maxretry  = 3
EOF
}

seedbox_apply_fail2ban() {
    local changed=0
    if write_if_changed "$FAIL2BAN_MAIN_CONF" 644 root:root fail2ban_generate_main; then changed=1; fi
    touch /var/log/fail2ban.log
    if write_if_changed "$FAIL2BAN_JAIL" 644 root:root fail2ban_generate_jail; then changed=1; fi
    if ((changed)) || ! systemctl is-active --quiet fail2ban; then
        systemctl enable --quiet fail2ban 2>/dev/null || true
        run 'Restarting fail2ban' systemctl restart fail2ban
    fi
    # also at boot (it may have been turned off there)
    unit_ensure_on "$(t 'Enabling %s at boot' fail2ban)" fail2ban
}

# Puts the seedbox in the state described in /etc/seedtunnel (idempotent)
seedbox_apply() {
    apt_install transmission-daemon nginx certbot fail2ban python3-systemd bind9-dnsutils inotify-tools
    net_hardening_apply
    seedbox_apply_user
    seedbox_save
    # the site of the seedbox serves the links: it takes the place of the
    # site of the links of the VPN (same file, same certificates)
    rm -f "$LINKS_CONF_FILE"
    # ports 80/443 open before the Let's Encrypt request
    firewall_refresh
    seedbox_apply_dirs
    seedbox_apply_apparmor
    seedbox_apply_transmission
    seedbox_apply_htpasswd
    seedbox_apply_https
    seedbox_apply_sftp
    seedbox_apply_fail2ban
    diskguard_install
    seedbox_save
}

# --- Check and summary -------------------------------------------------------------

# Authenticated request without a session token: Transmission answers 409 if
# HTTPS, nginx and both passwords work. Without a known password, we only
# check that access is refused (401).
seedbox_curl_auth() {
    local credentials="$SEEDBOX_USER:$SEEDBOX_NEW_PASSWORD"
    credentials=${credentials//\\/\\\\}
    credentials=${credentials//\"/\\\"}
    printf 'user = "%s"\n' "$credentials"
}

seedbox_http_code() {
    local -a target
    if is_ipv4 "$SEEDBOX_DOMAIN"; then
        target=(-H "Host: $SEEDBOX_DOMAIN" "https://127.0.0.1$1")
    else
        target=(--resolve "$SEEDBOX_DOMAIN:443:127.0.0.1" "https://$SEEDBOX_DOMAIN$1")
    fi
    if [[ ${2-} == auth ]]; then
        seedbox_curl_auth | curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -K - "${target[@]}" 2>/dev/null || true
    else
        curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${target[@]}" 2>/dev/null || true
    fi
}

seedbox_selftest() {
    local code="" attempt
    for attempt in 1 2 3 4 5; do
        if [[ -n $SEEDBOX_NEW_PASSWORD ]]; then
            code=$(seedbox_http_code /transmission/rpc auth)
        else
            code=$(seedbox_http_code /transmission/web/)
        fi
        # 502: Transmission still starting
        [[ $code == 502 ]] || break
        sleep 2
    done
    case $code in
        409) ok 'Login test on the web interface: passed' ;;
        401)
            if [[ -n $SEEDBOX_NEW_PASSWORD ]]; then
                warn 'Login test: credentials refused (details in %s).' "$APP_LOG"
            else
                ok 'Web interface online and protected by a password'
            fi
            ;;
        502) warn 'Login test: nginx cannot reach Transmission (journalctl -u transmission-daemon).' ;;
        *) warn 'Login test: unexpected answer (code %s).' "${code:-$(t 'none')}" ;;
    esac
}

# First port on which SSH listens
ssh_first_port() {
    local settings
    settings=$(sshd_settings)
    awk '$1 == "port" && !found { print $2; found = 1 }' <<<"$settings"
}

seedbox_summary() {
    local port
    port=$(ssh_first_port)
    port=${port:-22}
    echo
    text seedbox_summary
}

# --- SFTP connection settings (WinSCP, FileZilla) -------------------------------------

# Fingerprint of the key of the server, shown by SFTP programs at the first
# connection (e.g. « SHA256:szUj…NT8 ED25519 »): empty if not found
host_key_fingerprint() {
    local file=/etc/ssh/ssh_host_ed25519_key.pub
    [[ -r $file ]] || return 0
    ssh-keygen -l -E sha256 -f "$file" 2>/dev/null | awk '{ gsub(/[()]/, "", $NF); print $2, $NF }' || true
}

# Fingerprint in the format of WinSCP addresses: « ssh-ed25519-<SHA-256> »,
# base64 padded with « = », with « - » instead of « + » and « _ » instead of
# « / » (https://winscp.net/eng/docs/session_url)
host_key_fingerprint_url() {
    local file=/etc/ssh/ssh_host_ed25519_key.pub fingerprint
    [[ -r $file ]] || return 0
    fingerprint=$(ssh-keygen -l -E sha256 -f "$file" 2>/dev/null | awk '{ print $2 }' || true)
    fingerprint=${fingerprint#SHA256:}
    [[ -n $fingerprint ]] || return 0
    while ((${#fingerprint} % 4)); do fingerprint+="="; done
    fingerprint=${fingerprint//+/-}
    fingerprint=${fingerprint//\//_}
    printf 'ssh-ed25519-%s' "$fingerprint"
}

# Address to paste into WinSCP, with the fingerprint of the server when known:
# WinSCP then checks the key of the server by itself, without a question
winscp_url() {
    local port=$1 fingerprint
    fingerprint=$(host_key_fingerprint_url)
    if [[ -n $fingerprint ]]; then
        printf 'sftp://%s;fingerprint=%s@%s:%s/' "$SEEDBOX_USER" "$fingerprint" "$SEEDBOX_DOMAIN" "$port"
    else
        printf 'sftp://%s@%s:%s/' "$SEEDBOX_USER" "$SEEDBOX_DOMAIN" "$port"
    fi
}

# Site to import into FileZilla (File → Import…). Logontype 2: the password is
# asked at connection time, it is not in the file.
filezilla_generate_site() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<FileZilla3>
    <Servers>
        <Server>
            <Host>$SEEDBOX_DOMAIN</Host>
            <Port>$1</Port>
            <Protocol>1</Protocol>
            <Type>0</Type>
            <User>$SEEDBOX_USER</User>
            <Logontype>2</Logontype>
            <TimezoneOffset>0</TimezoneOffset>
            <PasvMode>MODE_DEFAULT</PasvMode>
            <MaximumMultipleConnections>0</MaximumMultipleConnections>
            <EncodingType>Auto</EncodingType>
            <BypassProxy>0</BypassProxy>
            <Name>Seedbox $SEEDBOX_DOMAIN</Name>
            <Comments />
            <Colour>0</Colour>
            <LocalDir />
            <RemoteDir />
            <SyncBrowsing>0</SyncBrowsing>
            <DirectoryComparison>0</DirectoryComparison>
        </Server>
    </Servers>
</FileZilla3>
EOF
}

# Site to import into WinSCP (login window → Tools → Import Sites → INI file):
# a WinSCP.ini that holds this site only. Sites already saved are kept (same
# name: WinSCP adds a number). No password in it: it is asked at connection
# time. Protocol not written: SFTP is the default. Windows line ends, as in
# the files WinSCP writes. The name of the site is escaped as WinSCP does it
# (« %20 » for a space).
# With it, the fingerprint of the server: WinSCP imports it with the site into
# the keys it knows, and accepts a fingerprint there instead of a whole key.
# It then checks the server by itself, without a question at the first
# connection (as with the address of winscp_url).
# With a key made by seedtunnel: the site uses it, from the .ssh folder of the
# personal folder (%USERPROFILE%, replaced by WinSCP at connection time;
# written « %25 » and « %5C » for « % » and « \ », as in WinSCP.ini).
winscp_generate_site() {
    local port=$1 name="Seedbox $SEEDBOX_DOMAIN" fingerprint
    fingerprint=$(host_key_fingerprint_url)
    printf '[Sessions\\%s]\r\nHostName=%s\r\nPortNumber=%s\r\nUserName=%s\r\n' \
        "${name// /%20}" "$SEEDBOX_DOMAIN" "$port" "$SEEDBOX_USER"
    if sftp_has_seedtunnel_key; then
        printf 'PublicKeyFile=%%25USERPROFILE%%25%%5C.ssh%%5Cseedbox-%s.ppk\r\n' "$SEEDBOX_USER"
    fi
    if [[ -n $fingerprint ]]; then
        printf '\r\n[SshHostKeys]\r\nssh-ed25519@%s:%s=%s\r\n' "$port" "$SEEDBOX_DOMAIN" "${fingerprint%%=*}"
    fi
}

# sftp_profile_share winscp|filezilla PORT — link to the site to import into
# WinSCP or FileZilla
sftp_profile_share() {
    local program=$1 port=$2 tmp fingerprint key_in_profile=0
    systemctl is-active --quiet nginx || die 'nginx is stopped:  seedtunnel seedbox restart'
    fingerprint=$(host_key_fingerprint)
    if [[ $program == winscp ]] && sftp_has_seedtunnel_key; then key_in_profile=1; fi
    tmp=$(mktemp)
    if [[ $program == winscp ]]; then
        winscp_generate_site "$port" >"$tmp"
        share_create "$tmp" "seedbox-winscp.ini" "$(t 'SFTP connection to the seedbox (WinSCP)')" \
            "$(text share_steps_winscp)" "$(t 'The file holds no password.')"
    else
        filezilla_generate_site "$port" >"$tmp"
        share_create "$tmp" "seedbox-filezilla.xml" "$(t 'SFTP connection to the seedbox (FileZilla)')" \
            "$(text share_steps_filezilla)" "$(t 'The file holds no password.')"
    fi
    rm -f "$tmp"
    if ((key_in_profile)); then
        say 'The site uses the SSH key made by seedtunnel: keep the file seedbox-%s.ppk in %s (create the folder if needed).' "$SEEDBOX_USER" "$(windows_ssh_folder)"
    elif [[ $SEEDBOX_SFTP_PASSWORD == no ]]; then
        warn 'This server accepts SSH keys only: once the site is imported, give it your private key (steps on the page).'
    fi
}

# SFTP connection settings, and the address for WinSCP. On request (« winscp »
# or « filezilla »), a link to the profile to import into that program. In the
# menus, without a request: the settings and the choices (seedbox_sftp_screen).
seedbox_sftp_config() {
    local port fingerprint keys_only="" url
    port=$(ssh_first_port)
    port=${port:-22}
    fingerprint=$(host_key_fingerprint)
    if [[ $SEEDBOX_SFTP_PASSWORD == no ]]; then keys_only=" $(t '(SSH key only)')"; fi
    if [[ -z ${1-} ]] && ((INTERACTIVE)); then
        seedbox_sftp_screen "$port" "$fingerprint" "$keys_only"
        return 0
    fi
    url=$(winscp_url "$port")
    banner
    section 'SFTP connection (WinSCP, FileZilla)'
    seedbox_sftp_card "$port" "$fingerprint" "$keys_only"
    echo
    text sftp_config_help
    echo
    case ${1-} in
        winscp | filezilla) sftp_profile_share "$1" "$port" ;;
        *)
            say 'WinSCP: profile to import with  seedtunnel seedbox sftp-config winscp'
            say 'FileZilla: profile to import with  seedtunnel seedbox sftp-config filezilla'
            say 'Connection without a password: key for WinSCP / FileZilla with  seedtunnel seedbox sftp-key new'
            ;;
    esac
}

# seedbox_sftp_card PORT FINGERPRINT NOTE — what to type in WinSCP or
# FileZilla, in a frame
seedbox_sftp_card() {
    ui_width
    ui_field_add "$(t 'Protocol')" SFTP
    ui_field_add "$(t 'Host')" "$C_CYAN$SEEDBOX_DOMAIN$C_RESET"
    ui_field_add Port "$C_CYAN$1$C_RESET"
    ui_field_add "$(t 'User')" "$C_CYAN$SEEDBOX_USER$C_RESET$3"
    if [[ -n $2 ]]; then ui_field_add "$(t 'Fingerprint')" "$2"; fi
    ui_box_fields good "$(t 'Settings of the connection')"
}

# In the menus: the settings, the profiles to import into WinSCP or FileZilla,
# and the two ways to connect without a password
seedbox_sftp_screen() {
    local port=$1 fingerprint=$2 keys_only=$3 choice
    while true; do
        banner
        section 'SFTP connection (WinSCP, FileZilla)'
        seedbox_sftp_card "$port" "$fingerprint" "$keys_only"
        echo
        ui_paragraph "$(t 'Profiles to import (one-time links):')"
        ui_menu_add 1 "$(t 'WinSCP profile')"
        ui_menu_add 2 "$(t 'FileZilla profile')"
        ui_menu_show
        echo
        sftp_key_choices 3 4
        echo
        ui_ask_choice choice b "$(t 'Back')" q "$(t 'Quit')"
        case ${choice,,} in
            1) ui_action seedbox_sftp_profile winscp "$port" ;;
            2) ui_action seedbox_sftp_profile filezilla "$port" ;;
            3) ui_action sftp_key_new_screen ;;
            4) ui_action sftp_key_add_screen ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# seedbox_sftp_profile winscp|filezilla PORT
seedbox_sftp_profile() {
    banner
    if [[ $1 == winscp ]]; then
        section 'WinSCP profile (one-time link)'
    else
        section 'FileZilla profile (one-time link)'
    fi
    sftp_profile_share "$1" "$2"
    pause
}

# sftp_key_choices KEY_NEW KEY_ADD — what an SSH key is, in words anyone can
# follow, and the two ways to get one: a new key made by seedtunnel (the
# simplest), or the public key of a key the user already has (the safest)
sftp_key_choices() {
    ui_paragraph "$(t 'Connection without a password (SSH key): an SSH key is two files. The private key stays on your computer, the public key goes on the server.')"
    ui_choices "$1" "$(t 'I have no key')" \
        "$(t 'seedtunnel creates one and gives you the private key through a one-time link. The simplest.')" \
        "$2" "$(t 'I already have a key')" \
        "$(t 'paste its public key (.pub file): the private key never leaves your computer. The safest.')"
}

# « I have no key »: a new key, its private part through a one-time link
sftp_key_new_screen() {
    banner
    section 'New SSH key (one-time link)'
    sftp_key_generate
    pause
}

# « I already have a key »: its public part, pasted. A private key pasted by
# mistake is named as such (and not kept anywhere).
sftp_key_add_screen() {
    local answer
    banner
    section 'Add my public key'
    ui_paragraph "$(t 'Paste the public key: one line, which starts with ssh-ed25519 or ssh-rsa. Never paste the private key.')"
    ui_paragraph "$(t 'Your key is a .ppk file of PuTTY? Open it in PuTTYgen: the public key is in the frame at the top.')"
    ui_paragraph "$(t 'Linux or macOS: your public key is in ~/.ssh/id_ed25519.pub (no key? ssh-keygen -t ed25519).')"
    echo
    if sftp_ask_public_key answer; then
        sftp_keys_import - <<<"$answer"
        seedbox_apply_sftp
        pause
    fi
}

# --- SSH keys for SFTP ---------------------------------------------------------------

# Adds the valid public keys of a file (- = standard input), without duplicates
# The keys are all checked first, then added in one go: one invalid key, and
# none is added.
sftp_keys_import() {
    local source=$1 line tmp count=0 file="$SFTP_KEYS_DIR/$SEEDBOX_USER"
    local -a keys=()
    local -A seen=()
    install -d -m 755 "$SFTP_KEYS_DIR"
    if [[ ! -e $file ]]; then install -m 644 /dev/null "$file"; fi
    tmp=$(mktemp)
    if [[ $source == - ]]; then cat >"$tmp"; else cat -- "$source" >"$tmp"; fi
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line || $line == \#* ]] && continue
        if ! ssh-keygen -l -f - <<<"$line" &>/dev/null; then
            rm -f "$tmp"
            die 'Invalid SSH key: %s…' "${line:0:40}"
        fi
        if [[ -z ${seen[$line]-} ]] && ! grep -qxF -- "$line" "$file"; then keys+=("$line"); fi
        seen[$line]=1
    done <"$tmp"
    rm -f "$tmp"
    count=${#keys[@]}
    if ((count)); then
        sftp_keys_write "$(cat -- "$file")" "${keys[@]}" || die 'Cannot write %s (disk full?).' "$file"
    fi
    if ((count)); then
        ok '%s SSH key(s) added for %s.' "$count" "$SEEDBOX_USER"
    else
        ok 'Key(s) already saved for %s.' "$SEEDBOX_USER"
    fi
}

# sftp_keys_write CONTENT [KEY…] — the file of the keys becomes CONTENT, plus
# the KEYs, replaced in one go: written next to it (same disk), readable by
# sshd (644), then renamed. If writing fails, the file stays as it was.
sftp_keys_write() {
    local content=$1 file="$SFTP_KEYS_DIR/$SEEDBOX_USER" tmp
    shift
    tmp=$(mktemp "$SFTP_KEYS_DIR/.keys.XXXXXX") || return 1
    if ! {
        if [[ -n $content ]]; then printf '%s\n' "$content"; fi
        if (($#)); then printf '%s\n' "$@"; fi
    } >"$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}

# Number of SSH keys saved for the SFTP account
sftp_keys_count() {
    local count=0 line
    [[ -s $SFTP_KEYS_DIR/$SEEDBOX_USER ]] || {
        echo 0
        return 0
    }
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] || count=$((count + 1))
    done <"$SFTP_KEYS_DIR/$SEEDBOX_USER"
    echo "$count"
}

# Menu questions: asked again when the answer is wrong. Status 1: back.
sftp_ask_public_key() {
    local _key_var=$1 _key _rest
    while true; do
        ask_back _key 'Public key' "" || return 1
        if ssh-keygen -l -f - <<<"$_key" &>/dev/null; then break; fi
        if [[ $_key == *"PRIVATE KEY"* || $_key == PuTTY-User-Key-File* ]]; then
            # the other lines of the pasted private key, not read as answers
            while IFS= read -r -t 1 _rest; do :; done
            warn 'This is a private key: it stays on your computer. Paste the public key (.pub file).'
            continue
        fi
        warn 'Invalid SSH key: %s…' "${_key:0:40}"
    done
    printf -v "$_key_var" '%s' "$_key"
}

sftp_ask_key_number() {
    local _number_var=$1 _number count
    count=$(sftp_keys_count)
    if ((count == 0)); then
        warn 'No SSH key saved for %s.' "$SEEDBOX_USER"
        pause
        return 1
    fi
    while true; do
        ask_back _number 'Number of the key to remove' "" || return 1
        if [[ $_number =~ ^[0-9]{1,9}$ ]] && ((10#$_number >= 1 && 10#$_number <= count)); then
            _number=$((10#$_number))
            break
        fi
        warn 'Key number %s not found.' "$_number"
    done
    printf -v "$_number_var" '%s' "$_number"
}

sftp_keys_list() {
    local index=0 line info
    if ! sftp_has_keys; then
        say 'No SSH key saved for %s.' "$SEEDBOX_USER"
        return 0
    fi
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] && continue
        index=$((index + 1))
        info=$(ssh-keygen -l -f - <<<"$line" 2>/dev/null || true)
        sftp_key_line "$index" "${info:-${line:0:50}}"
    done <"$SFTP_KEYS_DIR/$SEEDBOX_USER"
}

# sftp_key_line NUMBER INFO — a key of the list. INFO: what « ssh-keygen -l »
# says (« 256 SHA256:… comment (ED25519) »). For the commands, as it is. In
# the menus, on two lines that fit the screen: its name (the comment), then
# its type and the beginning and end of its fingerprint, in grey.
sftp_key_line() {
    local number=$1 info=$2 comment kind fingerprint pattern='^[0-9]+ (SHA256:[^ ]+) (.*) \(([^)]+)\)$'
    if ((!INTERACTIVE)) || [[ ! $info =~ $pattern ]]; then
        printf '  %2d) %s\n' "$number" "$info"
        return 0
    fi
    fingerprint=${BASH_REMATCH[1]}
    comment=${BASH_REMATCH[2]}
    kind=${BASH_REMATCH[3]}
    ui_print "  $(printf '%2d)' "$number") $comment"
    ui_print "      $C_GREY$kind · ${fingerprint:0:15}…${fingerprint: -6}$C_RESET"
}

sftp_keys_remove() {
    local number=$1 file="$SFTP_KEYS_DIR/$SEEDBOX_USER" index=0 line tmp found=0
    [[ $number =~ ^[0-9]{1,9}$ ]] || die 'Give the number of the key (seedtunnel seedbox sftp-key list).'
    number=$((10#$number))
    tmp=$(mktemp)
    while IFS= read -r line; do
        if [[ -n $line && $line != \#* ]]; then
            index=$((index + 1))
            if ((index == number)); then
                found=1
                continue
            fi
        fi
        printf '%s\n' "$line" >>"$tmp"
    done <"$file"
    if ((!found)); then
        rm -f "$tmp"
        die 'Key number %s not found.' "$number"
    fi
    if ! sftp_keys_write "$(cat -- "$tmp")"; then
        rm -f "$tmp"
        die 'Cannot write %s (disk full?).' "$file"
    fi
    rm -f "$tmp"
    if [[ $SEEDBOX_SFTP_PASSWORD == no ]] && ! sftp_has_keys; then
        SEEDBOX_SFTP_PASSWORD=yes
        seedbox_save
        warn 'No key left: the SFTP password is allowed again.'
    fi
    seedbox_apply_sftp
    ok 'Key number %s removed.' "$number"
}

# New SSH key for WinSCP / FileZilla: created here, its public part added to
# the allowed keys, its private part sent once as a .ppk file (PuTTY format,
# read by WinSCP and FileZilla) through a one-time link. No copy stays on the
# server. The key has no passphrase: it opens SFTP without a password.
sftp_key_generate() {
    local comment name="seedbox-$SEEDBOX_USER.ppk"
    systemctl is-active --quiet nginx || die 'nginx is stopped:  seedtunnel seedbox restart'
    apt_install putty-tools
    comment="seedtunnel-$SEEDBOX_USER-$(date +%Y%m%d-%H%M%S)"
    # in a subshell of its own: the temporary folder with the private key is
    # deleted whatever happens, even if a step stops the script
    in_subshell sftp_key_create_and_share "$comment" "$name"
    say 'Keep the file without renaming it, in a folder you keep. On Windows: %s (the WinSCP profile looks for it there).' "$(windows_ssh_folder)"
    say 'Link unused? Remove the key "%s" (seedtunnel seedbox sftp-key list) and create another one.' "$comment"
}

# sftp_key_create_and_share COMMENT NAME — in a subshell (in_subshell): its
# trap deletes the private key when the subshell ends
sftp_key_create_and_share() {
    local comment=$1 name=$2
    SFTP_KEY_TMP=$(mktemp -d)
    trap 'rm -rf "$SFTP_KEY_TMP"' EXIT
    if ! (umask 077 && ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$SFTP_KEY_TMP/key" \
        && puttygen "$SFTP_KEY_TMP/key" -O private -o "$SFTP_KEY_TMP/key.ppk" --ppk-param version=2) </dev/null >>"$APP_LOG" 2>&1; then
        die 'Cannot create the SSH key (details in %s).' "$APP_LOG"
    fi
    sftp_keys_import "$SFTP_KEY_TMP/key.pub"
    seedbox_apply_sftp
    share_create "$SFTP_KEY_TMP/key.ppk" "$name" "$(t 'SSH key of %s for WinSCP and FileZilla' "$SEEDBOX_USER")" \
        "$(text share_steps_sftp_key)" "$(t 'This key opens the seedbox without a password: keep it to yourself.')"
}

seedbox_set_sftp_password() {
    case $1 in
        on | yes) SEEDBOX_SFTP_PASSWORD=yes ;;
        off | no)
            sftp_has_keys || die 'Add an SSH key first (seedtunnel seedbox sftp-key add FILE).'
            SEEDBOX_SFTP_PASSWORD=no
            ;;
        *) die 'Usage: seedtunnel seedbox sftp-password on|off' ;;
    esac
    seedbox_save
    seedbox_apply_sftp
    if [[ $SEEDBOX_SFTP_PASSWORD == yes ]]; then
        ok 'SFTP: password allowed.'
    else
        ok 'SFTP: SSH keys only (the password still works for the web interface).'
    fi
}

sftp_keys_menu_remove() {
    local answer
    if sftp_ask_key_number answer; then
        sftp_keys_remove "$answer"
        pause
    fi
}

sftp_keys_menu_password() {
    if [[ $SEEDBOX_SFTP_PASSWORD == yes ]]; then seedbox_set_sftp_password off; else seedbox_set_sftp_password on; fi
    pause
}

# State of the SFTP password for the menus: allowed in yellow (an SSH key is
# safer), refused in green
sftp_password_state() {
    if [[ $SEEDBOX_SFTP_PASSWORD == yes ]]; then
        printf '%s! %s%s' "$C_YELLOW" "$(t 'allowed (an SSH key is safer)')" "$C_RESET"
    else
        printf '%s● %s%s' "$C_GREEN" "$(t 'refused (keys only)')" "$C_RESET"
    fi
}

sftp_keys_menu() {
    local choice
    while true; do
        seedbox_load
        UI_PLACE=(Seedbox "$(t 'SSH keys for SFTP')")
        ui_top "${UI_PLACE[@]}"
        sftp_keys_list
        echo
        ui_field_add "$(t 'SFTP password')" "$(sftp_password_state)"
        ui_fields_show
        echo
        sftp_key_choices 1 2
        echo
        ui_menu_add 3 "$(t 'Remove a key')"
        ui_menu_add 4 "$(t 'Allow / refuse the password in SFTP')"
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action sftp_key_new_screen ;;
            2) ui_action sftp_key_add_screen ;;
            3) ui_action sftp_keys_menu_remove ;;
            4) ui_action sftp_keys_menu_password ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# --- Actions ---------------------------------------------------------------------------

# The questions of the installation. Status 1: the user went back.
seedbox_install_questions() {
    local ip=$1 certificate
    seedbox_ask_user "" || return 1
    SEEDBOX_USER=$OPT_NEW_USER
    echo
    seedbox_ask_domain "$ip" || return 1
    echo
    while true; do
        ask_back SEEDBOX_DATA_DIR 'Data folder' "$SEEDBOX_DATA_DIR" || return 1
        if seedbox_check_data_dir "$SEEDBOX_DATA_DIR"; then break; fi
    done
    certificate="Let's Encrypt"
    if [[ $SEEDBOX_LETSENCRYPT_SERVER == staging ]]; then certificate=$(t "Let's Encrypt (test server)"); fi
    if [[ $SEEDBOX_LETSENCRYPT == no ]]; then certificate=$(t 'self-signed'); fi
    echo
    say 'Summary:'
    say '  User        : %s' "$SEEDBOX_USER"
    say '  Address     : %s' "https://$SEEDBOX_DOMAIN/"
    say '  Certificate : %s' "$certificate"
    say '  Data        : %s' "$SEEDBOX_DATA_DIR"
    echo
    confirm 'Start the installation?' y
}

seedbox_install_interactive() {
    local ip
    banner
    section 'Seedbox installation'
    ufw_refuse
    seedbox_check_web_ports
    base_setup
    apt_install bind9-dnsutils
    echo
    printf '%s ' "$(t 'Looking for the public IP address…')"
    ip=$(public_ipv4)
    echo "${ip:-$(t 'not found')}"
    SEEDBOX_DOMAIN=$(seedbox_guess_domain "$ip")
    SEEDBOX_DATA_DIR=$(seedbox_default_data_dir)
    if ((OPT_STAGING)); then SEEDBOX_LETSENCRYPT_SERVER=staging; fi
    echo
    # going back (empty answer, or « no » at the end): the seedbox is not installed
    if ! seedbox_install_questions "$ip"; then
        SEEDBOX_NEW_PASSWORD=""
        return 0
    fi
    echo
    seedbox_apply
    echo
    seedbox_selftest
    banner
    section 'Seedbox installed — no restart needed'
    seedbox_summary
    SEEDBOX_NEW_PASSWORD=""
    echo
    pause
}

# Installation (or putting back in order) from a --config file
seedbox_install_from_config() {
    local password password_file ip generated=0 first=1 keys current_user=$SEEDBOX_USER
    if seedbox_installed; then first=0; fi
    ufw_refuse
    base_setup
    apt_install bind9-dnsutils

    SEEDBOX_USER=$(config_get SEEDBOX_USER "${SEEDBOX_USER:-lancelot}")
    seedbox_is_valid_user "$SEEDBOX_USER" || die 'Invalid SEEDBOX_USER: "%s"' "$SEEDBOX_USER"
    if ((first)) && id "$SEEDBOX_USER" &>/dev/null; then
        die 'SEEDBOX_USER: the user "%s" already exists on this system.' "$SEEDBOX_USER"
    fi
    if ((!first)) && [[ $current_user != "$SEEDBOX_USER" ]]; then
        die 'Renaming the user goes through:  seedtunnel seedbox password --user %s' "$SEEDBOX_USER"
    fi

    SEEDBOX_DATA_DIR=$(config_get SEEDBOX_DATA_DIR "${SEEDBOX_DATA_DIR:-$(seedbox_default_data_dir)}")
    seedbox_check_data_dir "$SEEDBOX_DATA_DIR" || die 'SEEDBOX_DATA_DIR refused: "%s"' "$SEEDBOX_DATA_DIR"

    SEEDBOX_DOMAIN=$(config_get SEEDBOX_DOMAIN "$SEEDBOX_DOMAIN")
    SEEDBOX_DOMAIN=${SEEDBOX_DOMAIN,,}
    if [[ -z $SEEDBOX_DOMAIN ]]; then
        ip=$(public_ipv4)
        SEEDBOX_DOMAIN=$(seedbox_guess_domain "$ip")
    fi
    seedbox_is_valid_domain "$SEEDBOX_DOMAIN" || die 'Invalid SEEDBOX_DOMAIN: "%s"' "$SEEDBOX_DOMAIN"

    SEEDBOX_LETSENCRYPT=$(config_get SEEDBOX_LETSENCRYPT "$SEEDBOX_LETSENCRYPT")
    [[ $SEEDBOX_LETSENCRYPT =~ ^(auto|yes|no)$ ]] || die 'SEEDBOX_LETSENCRYPT: auto, yes or no'
    SEEDBOX_LETSENCRYPT_SERVER=$(config_get SEEDBOX_LETSENCRYPT_SERVER "$SEEDBOX_LETSENCRYPT_SERVER")
    if ((OPT_STAGING)); then SEEDBOX_LETSENCRYPT_SERVER=staging; fi
    [[ $SEEDBOX_LETSENCRYPT_SERVER =~ ^(production|staging)$ ]] || die 'SEEDBOX_LETSENCRYPT_SERVER: production or staging'
    SEEDBOX_SFTP_PASSWORD=$(config_get SEEDBOX_SFTP_PASSWORD "$SEEDBOX_SFTP_PASSWORD")
    [[ $SEEDBOX_SFTP_PASSWORD =~ ^(yes|no)$ ]] || die 'SEEDBOX_SFTP_PASSWORD: yes or no'

    # Password: file, value, or generated at the first installation.
    # If it is the one already in place, nothing is changed.
    password=$(config_get SEEDBOX_PASSWORD)
    password_file=$(config_get SEEDBOX_PASSWORD_FILE)
    if [[ -n $password_file ]]; then
        [[ -r $password_file ]] || die 'SEEDBOX_PASSWORD_FILE not found: %s' "$password_file"
        secret_file_check "$password_file"
        IFS= read -r password <"$password_file" || true
    fi
    if [[ -n $password ]]; then
        ((${#password} >= 10)) || die 'Seedbox password: at least 10 characters.'
        if seedbox_password_matches "$password"; then SEEDBOX_NEW_PASSWORD=""; else SEEDBOX_NEW_PASSWORD=$password; fi
    elif [[ -z $SEEDBOX_HASH_WEB ]]; then
        SEEDBOX_NEW_PASSWORD=$(generate_password)
        generated=1
    fi

    keys=$(config_get SEEDBOX_SSH_KEYS_FILE)
    if ((first)); then seedbox_check_web_ports; fi
    if [[ -n $keys ]]; then
        [[ -r $keys ]] || die 'SEEDBOX_SSH_KEYS_FILE not found: %s' "$keys"
        sftp_keys_import "$keys"
    fi

    seedbox_apply
    seedbox_selftest
    seedbox_summary
    if ((generated)); then warn 'Password generated automatically: write it down, it will not be shown again.'; fi
    SEEDBOX_NEW_PASSWORD=""
}

# Changes the password (and possibly the name) of the seedbox user
seedbox_set_credentials() {
    local new=$1 old=$SEEDBOX_USER
    if [[ $new != "$old" ]]; then
        seedbox_is_valid_user "$new" || die 'Invalid user name: "%s"' "$new"
        if id "$new" &>/dev/null; then die '"%s" already exists on this system.' "$new"; fi
        # seedbox_apply resumes it once the rule applies to the new name
        seedbox_rename_account "$old" "$new"
        SEEDBOX_USER=$new
        seedbox_save
    fi
    seedbox_apply
}

# Status 1: the user went back, nothing changed
seedbox_change_credentials() {
    WENT_BACK=0
    banner
    section 'Change the user or the password'
    if ! seedbox_ask_user "$SEEDBOX_USER"; then
        WENT_BACK=1
        return 0
    fi
    echo
    if ! confirm "$(t 'Save the user %s with this password?' "$OPT_NEW_USER")" y; then
        SEEDBOX_NEW_PASSWORD=""
        WENT_BACK=1
        return 0
    fi
    echo
    seedbox_set_credentials "$OPT_NEW_USER"
    echo
    seedbox_selftest
    echo
    seedbox_login_card
    SEEDBOX_NEW_PASSWORD=""
}

# After a change of the user or the password: how to log in now, in a frame
seedbox_login_card() {
    local port
    port=$(ssh_first_port)
    port=${port:-22}
    ui_width
    ui_field_add "$(t 'Web interface')" "${C_CYAN}https://$SEEDBOX_DOMAIN/$C_RESET"
    ui_field_add SFTP "$(t '%s, port %s' "$C_CYAN$SEEDBOX_DOMAIN$C_RESET" "$port")"
    ui_field_add "$(t 'User')" "$C_CYAN$SEEDBOX_USER$C_RESET"
    if [[ -n $SEEDBOX_NEW_PASSWORD ]]; then ui_field_add "$(t 'Password')" "$C_BOLD$SEEDBOX_NEW_PASSWORD$C_RESET"; fi
    ui_box_fields ok "$(t 'New login saved')"
    if [[ -n $SEEDBOX_NEW_PASSWORD ]]; then warn 'Write this down: the password is not saved anywhere in clear.'; fi
}

# seedtunnel seedbox password [--user NAME]: typed, or read from standard input
seedbox_cli_password() {
    local new=${OPT_NEW_USER:-$SEEDBOX_USER}
    if [[ -t 0 ]]; then
        INTERACTIVE=1
        ask_password SEEDBOX_NEW_PASSWORD
    else
        IFS= read -r SEEDBOX_NEW_PASSWORD || true
        ((${#SEEDBOX_NEW_PASSWORD} >= 10)) || die 'Password: at least 10 characters (read from standard input).'
    fi
    seedbox_set_credentials "$new"
    seedbox_selftest
    SEEDBOX_NEW_PASSWORD=""
    ok 'Credentials updated for %s.' "$SEEDBOX_USER"
}

seedbox_set_domain() {
    local name=${1,,}
    seedbox_is_valid_domain "$name" || die 'Invalid domain name: "%s"' "$name"
    SEEDBOX_DOMAIN=$name
    SEEDBOX_LETSENCRYPT=auto
    if ((OPT_STAGING)); then SEEDBOX_LETSENCRYPT_SERVER=staging; else SEEDBOX_LETSENCRYPT_SERVER=production; fi
    seedbox_apply_https
    seedbox_save
    ok 'Seedbox available at %s (certificate %s)' "https://$SEEDBOX_DOMAIN/" "$(seedbox_certificate_label)"
}

# Menu: change the domain. Nothing is touched before the end: an empty answer
# goes back, and replacing a valid Let's Encrypt certificate is confirmed first
# (Let's Encrypt limits how many certificates a name can get each week).
seedbox_change_domain() {
    local ip server had_letsencrypt=0
    local old_domain=$SEEDBOX_DOMAIN old_letsencrypt=$SEEDBOX_LETSENCRYPT old_server=$SEEDBOX_LETSENCRYPT_SERVER
    WENT_BACK=0
    banner
    section 'Domain name and HTTPS certificate'
    say 'Right now: %s (certificate %s)' "https://$SEEDBOX_DOMAIN/" "$(seedbox_certificate_label)"
    if [[ $SEEDBOX_CERTIFICATE != selfsigned ]] && letsencrypt_usable "$SEEDBOX_LETSENCRYPT_SERVER"; then
        had_letsencrypt=1
        say '  valid until %s, renewed automatically' "$(letsencrypt_expiry_date)"
    fi
    echo
    printf '%s ' "$(t 'Looking for the public IP address…')"
    ip=$(public_ipv4)
    echo "${ip:-$(t 'not found')}"
    echo
    if ! seedbox_ask_domain "$ip" change; then
        WENT_BACK=1
        return 0
    fi
    if ((OPT_STAGING)); then server=staging; else server=production; fi
    echo
    if ((had_letsencrypt)); then
        if [[ $SEEDBOX_LETSENCRYPT != no ]] && letsencrypt_usable "$server"; then
            # same name, certificate still valid: nothing to request
            SEEDBOX_LETSENCRYPT=$old_letsencrypt
            ok 'Nothing to change: %s keeps its certificate.' "https://$SEEDBOX_DOMAIN/"
            return 0
        fi
        if [[ $SEEDBOX_LETSENCRYPT == no ]]; then
            warn "The Let's Encrypt certificate will no longer be used: browsers will show a warning."
        else
            warn 'The certificate of %s will be deleted and a new one requested for %s.' "$old_domain" "$SEEDBOX_DOMAIN"
            say "  Let's Encrypt issues at most 5 certificates a week for the same name: avoid going back and forth."
        fi
        if ! confirm 'Continue?' n; then
            SEEDBOX_DOMAIN=$old_domain
            SEEDBOX_LETSENCRYPT=$old_letsencrypt
            SEEDBOX_LETSENCRYPT_SERVER=$old_server
            WENT_BACK=1
            return 0
        fi
        echo
    fi
    SEEDBOX_LETSENCRYPT_SERVER=$server
    seedbox_apply_https
    seedbox_save
    echo
    ok 'Seedbox available at %s (certificate %s)' "https://$SEEDBOX_DOMAIN/" "$(seedbox_certificate_label)"
}

FAIL2BAN_JAILS=(sshd nginx-http-auth recidive)
# the addresses of the table shown last, in its order (picked by their number)
FAIL2BAN_LISTED=()

# The addresses banned right now, one line each: « IP<tab>jail<tab>end of the
# ban » (seconds since 1970, -1: no end), the soonest freed first. fail2ban
# writes « 203.0.113.7 	2026-11-11 03:12:44 + 3600 = 2026-11-11 04:12:44 ».
fail2ban_bans() {
    local jail line end
    local pattern='^([0-9A-Fa-f.:]+)[[:space:]]+[0-9-]+ [0-9:]+ \+ (-?[0-9]+) = ([0-9-]+ [0-9:]+)$'
    for jail in "${FAIL2BAN_JAILS[@]}"; do
        while IFS= read -r line; do
            [[ $line =~ $pattern ]] || continue
            if ((BASH_REMATCH[2] < 0)); then
                end=-1
            else
                end=$(date -d "${BASH_REMATCH[3]}" +%s 2>/dev/null) || continue
            fi
            printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "$jail" "$end"
        done < <(fail2ban-client get "$jail" banip --with-time 2>/dev/null || true)
    done | sort -t $'\t' -k3,3n | awk -F '\t' '$3 == -1 { last = last $0 "\n"; next } { print } END { printf "%s", last }'
}

# fail2ban_ban_end END — « 04:12 (in 42 min) », « 2026-11-18 04:12 (in 7
# days) », or « never » for a ban with no end
fail2ban_ban_end() {
    local end=$1 now left when
    if ((end < 0)); then
        t 'never (banned for good)'
        return 0
    fi
    now=$(date +%s)
    left=$((end - now))
    if ((left < 0)); then left=0; fi
    if [[ $(date -d "@$end" +%F) == "$(date +%F)" ]]; then when=$(date -d "@$end" +%R); else when=$(date -d "@$end" '+%F %R'); fi
    if ((left < 3600)); then
        printf '%s %s' "$when" "$(t '(in %s min)' "$(((left + 59) / 60))")"
    elif ((left < 86400)); then
        printf '%s %s' "$when" "$(t '(in %s h)' "$((left / 3600))")"
    else
        printf '%s %s' "$when" "$(t '(in %s days)' "$((left / 86400))")"
    fi
}

# Table of the banned addresses, numbered (FAIL2BAN_LISTED: the addresses, in
# the same order), or « no address banned »; then what each jail does
fail2ban_bans_print() {
    local ban ip jail end index=0 total=0 count
    local -a rows=()
    FAIL2BAN_LISTED=()
    if ! systemctl is-active --quiet fail2ban; then
        warn 'fail2ban is not running: nobody is banned right now.   → seedtunnel seedbox restart'
        return 0
    fi
    while IFS= read -r ban; do
        IFS=$'\t' read -r ip jail end <<<"$ban"
        index=$((index + 1))
        FAIL2BAN_LISTED+=("$ip")
        rows+=("$index)"$'\t'"$ip"$'\t'"$jail"$'\t'"$(fail2ban_ban_end "$end")")
    done < <(fail2ban_bans)
    if ((index == 0)); then
        ok 'No address banned right now.'
    else
        ui_width
        ui_table ""$'\t'"$(t 'ADDRESS')"$'\t'JAIL$'\t'"$(t 'BANNED UNTIL')" "${rows[@]}"
    fi
    for jail in "${FAIL2BAN_JAILS[@]}"; do
        count=$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Total banned:[[:space:]]*//p' || true)
        if [[ $count =~ ^[0-9]+$ ]]; then total=$((total + count)); fi
    done
    echo
    printf '  %s\n' "$(t 'Bans since fail2ban started: %s.' "$total")"
    printf '  %s%s%s\n' "$C_GREY" "$(t 'sshd = SSH/SFTP (1 h) · nginx-http-auth = web interface (1 h)')" "$C_RESET"
    printf '  %s%s%s\n' "$C_GREY" "$(t 'recidive = banned 3 times in 24 h (1 week)')" "$C_RESET"
    printf '  %s%s%s\n' "$C_GREY" "$(t 'Banned? The VPN still connects, and nobody is banned through it.')" "$C_RESET"
}

fail2ban_unban() {
    [[ $1 =~ ^[0-9A-Fa-f.:]+$ ]] || die 'Invalid IP address: "%s"' "$1"
    run "$(t 'Unbanning %s' "$1")" fail2ban-client unban "$1"
}

fail2ban_bans_menu() {
    local ip
    banner
    section 'Banned IP addresses (fail2ban)'
    fail2ban_bans_print
    if ((${#FAIL2BAN_LISTED[@]} == 0)); then
        pause
        return 0
    fi
    echo
    while true; do
        ask_back ip 'Address to unban (number or IP)' "" || return 0
        if [[ $ip =~ ^[0-9]{1,9}$ ]] && ((10#$ip >= 1 && 10#$ip <= ${#FAIL2BAN_LISTED[@]})); then
            ip=${FAIL2BAN_LISTED[10#$ip - 1]}
            break
        fi
        if [[ $ip =~ ^[0-9A-Fa-f.:]+$ && $ip == *[.:]* ]]; then break; fi
        warn 'Invalid IP address: "%s"' "$ip"
    done
    fail2ban_unban "$ip"
    pause
}

seedbox_restart() {
    local service
    echo
    for service in nginx fail2ban; do
        run "$(t 'Restarting %s' "$service")" systemctl restart "$service"
    done
    if diskguard_stopped; then
        warn 'Transmission stays stopped: the disk is almost full (%s GB free). It restarts by itself above %s GB.' \
            "$(disk_free_gb "$SEEDBOX_DATA_DIR")" "$DISKGUARD_START_ABOVE_GB"
    else
        run "$(t 'Restarting %s' transmission-daemon)" systemctl restart transmission-daemon
    fi
}

# Deletes the seedbox account, after closing its open SFTP sessions (they
# prevent the deletion). Stops the script if the account is still there.
seedbox_delete_user() {
    local attempt
    [[ -n $SEEDBOX_USER ]] && id "$SEEDBOX_USER" &>/dev/null || return 0
    log_title 'Deleting the user %s' "$SEEDBOX_USER"
    # the documents stay readable by root once the user is deleted
    if [[ -d $SEEDBOX_DATA_DIR/documents ]]; then chown -R root:root "$SEEDBOX_DATA_DIR/documents"; fi
    for attempt in 1 2 3; do
        pkill -KILL -u "$SEEDBOX_USER" >>"$APP_LOG" 2>&1 || true
        if userdel "$SEEDBOX_USER" >>"$APP_LOG" 2>&1 || ! id "$SEEDBOX_USER" &>/dev/null; then return 0; fi
        sleep 1
    done
    die 'Cannot delete the user %s (details in %s). The seedbox was not removed and its SFTP restrictions stay in place: run the removal again.' \
        "$SEEDBOX_USER" "$APP_LOG"
}

# The certificate of Let's Encrypt, under a title of its own in the log; only
# if there is one (not with an IP address: certbot would fill the log with
# « No certificate found »)
seedbox_letsencrypt_delete() {
    command -v certbot >/dev/null || return 0
    [[ -e $LETSENCRYPT_ROOT/renewal/$LETSENCRYPT_CERT_NAME.conf ]] || return 0
    log_run "Deleting the Let's Encrypt certificate" certbot delete --cert-name "$LETSENCRYPT_CERT_NAME" --non-interactive
}

seedbox_uninstall() {
    local delete_data=0 note
    banner
    section 'Remove the seedbox'
    # the last part removed: the weekly backup and its passphrase go too
    note=$(backup_removal_note vpn)
    if ((INTERACTIVE)); then
        if [[ -n $note ]]; then
            danger "$(t 'Remove the seedbox')" "$(text seedbox_uninstall_help | tr '\n' ' ')" "$note"
        else
            danger "$(t 'Remove the seedbox')" "$(text seedbox_uninstall_help | tr '\n' ' ')"
        fi
    else
        text seedbox_uninstall_help
        echo
        if [[ -n $note ]]; then danger "$(t 'Remove the seedbox')" "$note"; fi
    fi
    if ! confirm 'Remove the seedbox?' n; then return 0; fi
    if ((INTERACTIVE)); then
        if confirm "$(t 'ALSO delete all the data in %s?' "$SEEDBOX_DATA_DIR")" n; then delete_data=1; fi
    elif ((OPT_PURGE_DATA)); then
        delete_data=1
    fi
    echo
    # The account goes first: its SFTP restrictions (chroot, no tunnel) stay in
    # force until it is really gone. If it cannot be deleted, nothing else is
    # removed, so that running the removal again finishes the job.
    seedbox_delete_user
    diskguard_remove
    log_run 'Stopping Transmission' systemctl disable --now transmission-daemon
    if [[ -f $SSHD_SEEDBOX_CONF ]]; then
        rm -f "$SSHD_SEEDBOX_CONF"
        run 'Reloading SSH' systemctl try-reload-or-restart ssh.service
    fi
    pending_clear ssh
    pending_clear nginx
    # under titles of their own in the log: their lines are not read as those
    # of the step before
    seedbox_letsencrypt_delete
    log_run 'Stopping the download links in progress' systemctl stop 'seedtunnel-share-*'
    rm -rf "$SHARE_DIR" "$SHARE_DIR.jobs"
    rm -f "$NGINX_SITE_LINK" "$NGINX_SITE" "$NGINX_HTPASSWD" "$FAIL2BAN_JAIL" "$FAIL2BAN_MAIN_CONF" "$TRANSMISSION_DROPIN"
    rm -f "$SFTP_KEYS_DIR/$SEEDBOX_USER"
    rmdir "$SFTP_KEYS_DIR" "${TRANSMISSION_DROPIN%/*}" 2>/dev/null || true
    seedbox_remove_apparmor
    rm -rf "$SEEDBOX_SSL_DIR" "$LETSENCRYPT_WEBROOT"
    systemctl daemon-reload 2>/dev/null || true
    apt_purge transmission-daemon transmission-common nginx nginx-common certbot fail2ban inotify-tools putty-tools
    if ((delete_data)) && [[ -n $SEEDBOX_DATA_DIR && $SEEDBOX_DATA_DIR != / ]]; then
        run 'Deleting the data' rm -rf "${SEEDBOX_DATA_DIR:?}"
    fi
    rm -f "$SEEDBOX_CONF_FILE" "$SEEDBOX_SECRETS_FILE"
    net_hardening_cleanup
    firewall_refresh
    backup_auto_stop_if_unused
    echo
    if ((delete_data)); then
        ok 'Seedbox and data deleted.'
    else
        ok 'Seedbox removed. Your data stays in %s.' "$SEEDBOX_DATA_DIR"
    fi
    pause
}

seedbox_menu_credentials() {
    seedbox_change_credentials
    if ((!WENT_BACK)); then pause; fi
}

seedbox_menu_domain() {
    seedbox_change_domain
    if ((!WENT_BACK)); then pause; fi
}

seedbox_menu_sftp() { seedbox_sftp_config; }

seedbox_menu_restart() {
    seedbox_restart
    pause
}

# The state of the seedbox, at the top of its menu
seedbox_menu_fields() {
    local certificate transmission
    if [[ $SEEDBOX_CERTIFICATE == selfsigned ]]; then
        certificate="$C_YELLOW$(t 'self-signed')$C_RESET $(t "(option 2 to try Let's Encrypt again)")"
    else
        certificate=$(seedbox_certificate_label)
    fi
    transmission=$(service_state_short transmission-daemon)
    if diskguard_stopped; then transmission="$C_RED● $(t 'stopped: disk almost full')$C_RESET"; fi
    ui_field_add "$(t 'Web interface')" "${C_CYAN}https://$SEEDBOX_DOMAIN/$C_RESET"
    ui_field_add "$(t 'Certificate')" "$certificate"
    ui_field_add SFTP "$SEEDBOX_USER@$SEEDBOX_DOMAIN · $(disk_free_text "$SEEDBOX_DATA_DIR")"
    ui_field_add "$(t 'SFTP password')" "$(sftp_password_state)"
    # full names, short states: the line fits in 80 columns. A green dot alone:
    # it runs; a red dot with a word: it does not (readable without colors too)
    ui_field_add Services "Transmission $transmission · nginx $(service_state_short nginx) · fail2ban $(service_state_short fail2ban)"
    ui_fields_show
}

seedbox_menu() {
    local choice
    while true; do
        seedbox_load
        seedbox_installed || return 0
        UI_PLACE=(Seedbox)
        ui_top Seedbox
        seedbox_menu_fields
        echo
        ui_menu_add 1 "$(t 'Change the user or the password')"
        ui_menu_add 2 "$(t 'Domain name and HTTPS certificate')"
        ui_menu_add 3 "$(t 'SSH keys for SFTP')"
        ui_menu_add 4 "$(t 'SFTP connection (WinSCP, FileZilla)')"
        ui_menu_add 5 "$(t 'Banned IP addresses (fail2ban)')"
        ui_menu_gap
        ui_menu_add 6 "$(t 'Restart the services')"
        ui_menu_add 7 "$(t 'Remove the seedbox')"
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action seedbox_menu_credentials ;;
            2) ui_action seedbox_menu_domain ;;
            3) ui_action sftp_keys_menu ;;
            4) ui_action seedbox_menu_sftp ;;
            5) ui_action fail2ban_bans_menu ;;
            6) ui_action seedbox_menu_restart ;;
            7) ui_action seedbox_uninstall ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

seedbox_main() {
    seedbox_load
    if seedbox_installed; then seedbox_menu; else seedbox_install_interactive; fi
}

# seedtunnel seedbox <command> …
seedbox_cli() {
    local command=${1-}
    if (($#)); then shift; fi
    case $command in
        "")
            require_terminal
            seedbox_main
            ;;
        install)
            if [[ -n $OPT_CONFIG_FILE ]]; then
                config_load "$OPT_CONFIG_FILE"
                seedbox_install_from_config
                if [[ $(config_get FIREWALL) == yes ]]; then firewall_enable; fi
            else
                require_terminal
                if seedbox_installed; then die 'The seedbox is already installed (seedtunnel seedbox to manage it).'; fi
                seedbox_install_interactive
            fi
            ;;
        password)
            seedbox_require_installed
            seedbox_cli_password
            ;;
        domain)
            seedbox_require_installed
            [[ -n ${1-} ]] || die 'Usage: seedtunnel seedbox domain NAME [--staging]'
            seedbox_set_domain "$1"
            ;;
        sftp-config)
            seedbox_require_installed
            case ${1-} in
                "" | winscp | filezilla) seedbox_sftp_config "${1-}" ;;
                *) die 'Usage: seedtunnel seedbox sftp-config [winscp|filezilla]' ;;
            esac
            ;;
        sftp-key)
            seedbox_require_installed
            case ${1-} in
                add)
                    [[ -n ${2-} ]] || die 'Usage: seedtunnel seedbox sftp-key add FILE.pub   (- for standard input)'
                    sftp_keys_import "$2"
                    seedbox_apply_sftp
                    ;;
                new) sftp_key_generate ;;
                list) sftp_keys_list ;;
                remove) sftp_keys_remove "${2-}" ;;
                *) die 'Usage: seedtunnel seedbox sftp-key add|new|list|remove' ;;
            esac
            ;;
        sftp-password)
            seedbox_require_installed
            seedbox_set_sftp_password "${1-}"
            ;;
        bans)
            seedbox_require_installed
            fail2ban_bans_print
            ;;
        unban)
            seedbox_require_installed
            fail2ban_unban "${1-}"
            ;;
        restart)
            seedbox_require_installed
            seedbox_restart
            ;;
        uninstall)
            seedbox_require_installed
            seedbox_uninstall
            ;;
        *) die 'Unknown command: seedbox %s   (help: seedtunnel help)' "$command" ;;
    esac
}
