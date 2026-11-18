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
NGINX_HTPASSWD="/etc/nginx/seedtunnel.htpasswd"
SSHD_SEEDBOX_CONF="/etc/ssh/sshd_config.d/seedtunnel-seedbox.conf"
SFTP_KEYS_DIR="/etc/ssh/seedtunnel_authorized_keys"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/seedtunnel.local"
FAIL2BAN_MAIN_CONF="/etc/fail2ban/fail2ban.d/seedtunnel.local"
# Pending archive import, owned by the coordinating feature until success.
SEEDBOX_ENGINE_IMPORT_FROM=""
declare -gA SEEDBOX_ENGINE_IMPORT_RESULT=()
# Password being changed (never written to disk).
SEEDBOX_NEW_PASSWORD=""

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
    state_read "$SEEDBOX_CONF_FILE" seedbox.conf || return $?
    state_read "$SEEDBOX_SECRETS_FILE" seedbox.secrets
}

seedbox_save() {
    state_write "$SEEDBOX_CONF_FILE" SEEDBOX_USER SEEDBOX_DOMAIN SEEDBOX_DATA_DIR SEEDBOX_CERTIFICATE \
        SEEDBOX_LETSENCRYPT SEEDBOX_LETSENCRYPT_SERVER SEEDBOX_SFTP_PASSWORD
}

seedbox_installed() { [[ -f $SEEDBOX_CONF_FILE ]]; }

seedbox_require_installed() {
    seedbox_installed || die 'The seedbox is not installed:  seedtunnel seedbox install'
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

# Suggests a name that already points to this server: name of the machine, or
# reverse name given by the provider (e.g. vps-1234abcd.vps.ovh.net). Else the IP.
seedbox_guess_domain() {
    local ip=$1 candidate reverse
    reverse=$(dig +short -x "$ip" @9.9.9.9 2>/dev/null | sed -n '1s/\.$//p' || true)
    for candidate in "$(hostname --fqdn 2>/dev/null || true)" "$reverse"; do
        candidate=${candidate,,}
        if [[ -n $candidate ]] && ! is_ipv4 "$candidate" && is_domain_or_ipv4 "$candidate" \
            && dns_points_here "$candidate" "$ip"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '%s' "$ip"
}

# Another seedbox, before the one of seedtunnel is installed or restored:
# swizzin, or a Transmission that seedtunnel did not install (its settings
# would be written over)
seedbox_foreign_refuse() {
    seedbox_installed && return 0
    if [[ -d $CONFLICT_ROOT/etc/swizzin ]]; then
        refuse "$(t '%s is installed' swizzin)" \
            "$(t '%s runs its own torrent programs, web server and accounts.' swizzin)" \
            "$(t 'seedtunnel would replace them: nothing was changed.')" \
            "$(t 'To go on: a separate server for seedtunnel.')"
    fi
    if package_installed "$(engine_package)" && ! package_recorded "$(engine_package)"; then
        refuse "$(t 'Transmission already there')" \
            "$(t 'It was not installed by seedtunnel: its settings (download folder, password, ports) may be yours.')" \
            "$(t 'seedtunnel would replace them: nothing was changed.')" \
            "$(t 'To go on: put your files in a safe place and remove it yourself (sudo apt purge transmission-daemon), or use a separate server for seedtunnel.')"
    fi
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

# The two kinds of name the seedbox can have, and the certificate of each
seedbox_domain_choices() {
    if [[ ${1-} == change ]]; then
        ui_print_wrapped "  " "  " "$C_BOLD$(t 'New name of the seedbox, at your choice:')$C_RESET"
    else
        ui_print_wrapped "  " "  " "$C_BOLD$(t 'Name of the seedbox, at your choice:')$C_RESET"
    fi
    ui_print_wrapped "  $C_BRAND●$C_RESET " "    " "$(t "a domain name (yours, or the one given by the provider, e.g. vps-1234abcd.vps.ovh.net): Let's Encrypt certificate, trusted by browsers;")"
    ui_print_wrapped "  $C_BRAND●$C_RESET " "    " "$(t 'or the IP address of the server: self-signed certificate (the browser shows a warning to accept).')"
}

# Asks for the domain name and checks that it points to this server.
# Sets SEEDBOX_DOMAIN, and SEEDBOX_LETSENCRYPT: auto if Let's Encrypt has a
# chance, otherwise no. An empty answer or B goes back, with status 1, and
# nothing is changed. « change »: the seedbox is already installed.
seedbox_ask_domain() {
    local ip=$1 mode=${2-} ips choice answer default=$SEEDBOX_DOMAIN
    if [[ $mode == change ]]; then default=""; fi
    seedbox_domain_choices "$mode"
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
        if ! is_domain_or_ipv4 "$answer"; then
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
    local status
    # the status: see the contract at the top of engine.sh
    accounts_ensure "$SEEDBOX_USER" "$(engine_group)"
    status=$?
    if ((status)); then return "$status"; fi
    if [[ -n $SEEDBOX_NEW_PASSWORD ]]; then
        seedbox_hash_password
    elif [[ -z $SEEDBOX_HASH_SYSTEM || -z $SEEDBOX_HASH_WEB || -z $SEEDBOX_HASH_TRANSMISSION ]]; then
        die 'No known password for %s: set one with  seedtunnel seedbox password' "$SEEDBOX_USER"
    else
        accounts_restore_hash "$SEEDBOX_USER" "$SEEDBOX_HASH_SYSTEM"
    fi
}

# « umask » compared by its value: Transmission 4 writes it as text in octal
# (« "002" »), Transmission 3 as a number (2). Transmission 3 does not read the
# text (settings of Transmission 4, brought back by a restore on Debian 12) and
# writes 0 in its place: every file it downloads would then be writable by
# every account. So the text counts only with Transmission 4. Anything else:
# -1 (never the right value).

seedbox_apply_htpasswd() {
    write_if_changed "$NGINX_HTPASSWD" 640 root:www-data \
        printf '%s:%s\n' "$SEEDBOX_USER" "$SEEDBOX_HASH_WEB" || true
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

nginx_generate_site() {
    local domain=${1:-$SEEDBOX_DOMAIN} certificate=${2:-$SEEDBOX_CERTIFICATE}
    local hsts ipv6_80="" ipv6_443=""
    hsts=$(tls_nginx_hsts "$certificate")
    if [[ -e /proc/net/if_inet6 ]]; then
        ipv6_80=$'\n    listen [::]:80;'
        ipv6_443=$'\n    listen [::]:443 ssl;'
    fi
    cat <<EOF
# Written by seedtunnel — use the menu rather than editing this file.

$(share_generate_nginx_http)

server {
    listen 80;$ipv6_80
    server_name $domain;
    server_tokens off;
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
    server_name $domain;

$(tls_nginx_directives "$certificate" "$WEB_SSL_DIR" "$LETSENCRYPT_DIR")

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
        # Transmission sends its own: one is enough (the one of nginx, above)
        proxy_hide_header X-Frame-Options;
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
        alias $APP_DIR/$(web_page "$NGINX_STOPPED_PAGE");
        default_type text/html;
    }
EOF
}

sftp_has_keys() { sftp_account_has_keys "$SEEDBOX_USER" "$SFTP_KEYS_DIR"; }

# The .ssh folder of the personal folder on Windows, where the WinSCP profile
# looks for the key made by seedtunnel (as a value: printf would read « \U »)
windows_ssh_folder() { printf 'C:\\Users\\%s\\.ssh' "$(t 'YOUR-NAME')"; }

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

# The jails: SSH and the repeat offenders always (with the VPN alone too), the
# password of the web interface with the seedbox
fail2ban_generate_jail() {
    cat <<EOF
# Written by seedtunnel — protection against password guessing
[DEFAULT]
# The machine itself and the VPN clients are never banned
ignoreip  = 127.0.0.1/8 ::1 $VPN_SUBNET.0/24
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
EOF
    if seedbox_installed; then
        cat <<'EOF'

# Password of the web interface
[nginx-http-auth]
enabled = true
backend = auto
port    = http,https
logpath = /var/log/nginx/error.log
EOF
    fi
    cat <<'EOF'

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

# fail2ban against password guessing: with the seedbox, and with the VPN alone
# (the SSH of the administrator is on the Internet in both cases)
fail2ban_apply() {
    local changed=0
    apt_install fail2ban python3-systemd
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
    engine_install nginx certbot fail2ban python3-systemd bind9-dnsutils inotify-tools
    net_hardening_apply
    login_alerts_apply
    local OPERATION_FD=${OPERATION_FD-} _seedbox_apply_owner=""
    operation_begin _seedbox_apply_owner || return $?
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
    operation_end "$_seedbox_apply_owner" || return 1
    seedbox_apply_htpasswd
    seedbox_apply_https
    seedbox_apply_sftp
    fail2ban_apply
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

# Feature snapshot for the menu and doctor. No HTTP request, no persistent
# state; the disk guard is only observed, never started/stopped here.
seedbox_observe() {
    local -A _seedbox_engine=() _seedbox_nginx=() _seedbox_fail2ban=()
    local -n _seedbox_observed=$1
    engine_observe _seedbox_engine
    service_observe nginx _seedbox_nginx
    service_observe fail2ban _seedbox_fail2ban
    _seedbox_observed=(
        [engine_service]="$(engine_service_name)" [engine_name]="$(engine_display_name)"
        [engine_state]="${_seedbox_engine[state]}" [engine_boot]="${_seedbox_engine[boot]}"
        [nginx_state]="${_seedbox_nginx[state]}" [nginx_boot]="${_seedbox_nginx[boot]}"
        [fail2ban_state]="${_seedbox_fail2ban[state]}" [fail2ban_boot]="${_seedbox_fail2ban[boot]}"
        [disk_halt]=no [disk_resume_failed]=no [disk_resume_unknown]=no [disk_state_invalid]=no [restore_hold]=no [storage_state]=unknown [free_gb]=""
        [api_state]=not_checked
    )
    if restore_interrupted; then _seedbox_observed[restore_hold]=yes; fi
    if diskguard_state_invalid; then _seedbox_observed[disk_state_invalid]=yes; fi
    if diskguard_stopped; then
        _seedbox_observed[disk_halt]=yes
        if diskguard_start_failed; then _seedbox_observed[disk_resume_failed]=yes; fi
        if diskguard_restart_unconfirmed; then _seedbox_observed[disk_resume_unknown]=yes; fi
    fi
    local _seedbox_free
    _seedbox_free=$(disk_free_gb "${SEEDBOX_DATA_DIR-}")
    if [[ $_seedbox_free =~ ^[0-9]+$ ]]; then
        _seedbox_observed[storage_state]=measured
        _seedbox_observed[free_gb]=$_seedbox_free
    fi
}

seedbox_selftest() {
    local code="" attempt mode=protected state
    if [[ -n $SEEDBOX_NEW_PASSWORD ]]; then mode=login; fi
    for attempt in 1 2 3 4 5; do
        if [[ -n $SEEDBOX_NEW_PASSWORD ]]; then
            code=$(seedbox_http_code "$(engine_rpc_path)" auth)
        else
            code=$(seedbox_http_code "$(engine_web_path)")
        fi
        # 502: Transmission still starting
        [[ $code == 502 ]] || break
        sleep 2
    done
    state=$(http_access_state "$code" "$mode")
    case $state in
        handshake) ok 'Login test on the web interface: passed' ;;
        refused) warn 'Login test: credentials refused (details in %s).' "$APP_LOG" ;;
        protected) ok 'Web interface online and protected by a password' ;;
        upstream_unreachable) warn 'Login test: nginx cannot reach Transmission (journalctl -u transmission-daemon).' ;;
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
    # the address to paste is for WinSCP: not shown for FileZilla
    if [[ ${1-} != filezilla ]]; then
        text sftp_config_help
        echo
    fi
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
seedbox_sftp_screen() { access_sftp_menu; }

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
    ui_paragraph "$(t 'Paste the public key: one line, which starts with ssh-ed25519 or ssh-rsa, or the block saved by PuTTYgen. Never paste the private key.')"
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

# Menu questions: asked again when the answer is wrong. Status 1: back.
sftp_ask_public_key() {
    local _key_var=$1 _key _rest _status
    while true; do
        ask_back _key 'Public key' "" || return 1
        # the block saved by PuTTYgen, pasted: all its lines
        if [[ $_key == "---- BEGIN SSH2 PUBLIC KEY ----" ]]; then
            _status=0
            _key=$(ssh_pasted_block "$_key") || _status=$?
            if ((_status == 0)) && ssh-keygen -l -f - <<<"$_key" &>/dev/null; then break; fi
            warn 'This block of PuTTYgen cannot be read: copy the line of the frame at the top of PuTTYgen instead.'
            continue
        fi
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
# the menus, its name (the comment), then its type and its whole fingerprint
# in grey, aligned under the name; both wrapped to the screen, never cut.
sftp_key_line() {
    local number=$1 info=$2 comment kind fingerprint start indent part
    local pattern='^[0-9]+ (SHA256:[^ ]+) (.*) \(([^)]+)\)$'
    if ((!INTERACTIVE)) || [[ ! $info =~ $pattern ]]; then
        printf '  %2d) %s\n' "$number" "$info"
        return 0
    fi
    fingerprint=${BASH_REMATCH[1]}
    comment=${BASH_REMATCH[2]}
    kind=${BASH_REMATCH[3]}
    printf -v start '  %2d) ' "$number"
    printf -v indent '%*s' "${#start}" ''
    ui_wrap "$comment" $((UI_WIDTH - ${#start}))
    for part in "${UI_LINES[@]}"; do
        printf '%s%s\n' "$start" "$part"
        start=$indent
    done
    ui_wrap "$kind · $fingerprint" $((UI_WIDTH - ${#indent}))
    for part in "${UI_LINES[@]}"; do printf '%s%s%s%s\n' "$indent" "$C_GREY" "$part" "$C_RESET"; done
}

sftp_keys_remove() {
    local number=$1
    # the status: see the contract at the top of engine.sh
    sftp_account_keys_remove "$SEEDBOX_USER" "$SFTP_KEYS_DIR" "$number"
    local status=$?
    if ((status)); then return "$status"; fi
    if [[ $SEEDBOX_SFTP_PASSWORD == no ]] && ! sftp_has_keys; then
        SEEDBOX_SFTP_PASSWORD=yes
        seedbox_save
        warn 'No key left: the SFTP password is allowed again.'
    fi
    seedbox_apply_sftp
    ok 'Key number %s removed.' "$((10#$number))"
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
    if ! ssh_key_pair_create "$SFTP_KEY_TMP" "$comment"; then
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

sftp_keys_menu() { access_sftp_menu; }

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
    conflicts_refuse
    seedbox_foreign_refuse
    web_check_ports
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
    conflicts_refuse
    seedbox_foreign_refuse
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
    is_domain_or_ipv4 "$SEEDBOX_DOMAIN" || die 'Invalid SEEDBOX_DOMAIN: "%s"' "$SEEDBOX_DOMAIN"

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
    if ((first)); then web_check_ports; fi
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
    is_domain_or_ipv4 "$name" || die 'Invalid domain name: "%s"' "$name"
    SEEDBOX_DOMAIN=$name
    SEEDBOX_LETSENCRYPT=auto
    if ((OPT_STAGING)); then SEEDBOX_LETSENCRYPT_SERVER=staging; else SEEDBOX_LETSENCRYPT_SERVER=production; fi
    seedbox_apply_https
    seedbox_save
    ok 'Seedbox available at %s (certificate %s)' "https://$SEEDBOX_DOMAIN/" "$(seedbox_certificate_label)"
}

# seedbox_domain_card IP 1|0 — the address of the seedbox now, its certificate
# (its end and its renewal with Let's Encrypt: 1) and the public IP of the
# server, in a green frame
seedbox_domain_card() {
    local ip=$1 letsencrypt=$2 certificate expiry days
    if [[ $SEEDBOX_CERTIFICATE == selfsigned ]]; then
        certificate="$C_YELLOW$(t 'self-signed')$C_RESET $(t '(browser warning to accept)')"
    else
        certificate=$(seedbox_certificate_label)
    fi
    ui_field_add "$(t 'Address')" "${C_CYAN}https://$SEEDBOX_DOMAIN/$C_RESET"
    ui_field_add "$(t 'Certificate')" "$certificate"
    if ((letsencrypt)); then
        expiry=$(tls_certificate_expiry "$LETSENCRYPT_DIR/cert.pem")
        days=$(certificate_days_left "$LETSENCRYPT_DIR/cert.pem")
        if [[ -n $expiry && -n $days ]]; then
            ui_field_add "$(t 'Expires')" "$(t '%s (in %s days)' "$expiry" "$days")"
        elif [[ -n $expiry ]]; then
            ui_field_add "$(t 'Expires')" "$expiry"
        fi
        ui_field_add "$(t 'Renewed')" "$(t 'automatically')"
    fi
    ui_field_add "$(t 'Public IP')" "${ip:-$(t 'not found')}"
    ui_box_fields good "$(t 'Right now')"
}

# Menu: change the domain. Nothing is touched before the end: an empty answer
# goes back, and replacing a valid Let's Encrypt certificate is confirmed first
# (Let's Encrypt limits how many certificates a name can get each week).
seedbox_change_domain() {
    local ip server had_letsencrypt=0
    local old_domain=$SEEDBOX_DOMAIN old_letsencrypt=$SEEDBOX_LETSENCRYPT old_server=$SEEDBOX_LETSENCRYPT_SERVER
    WENT_BACK=0
    # the address first, under the menu: the screen comes once it is known
    printf '\n  %s' "$(t 'Looking for the public IP address…')"
    ip=$(public_ipv4)
    echo
    banner
    section 'Domain name and HTTPS certificate'
    if [[ $SEEDBOX_CERTIFICATE != selfsigned ]] && tls_acme_usable "$LETSENCRYPT_DIR/cert.pem" "$SEEDBOX_DOMAIN" "$SEEDBOX_LETSENCRYPT_SERVER"; then had_letsencrypt=1; fi
    seedbox_domain_card "$ip" "$had_letsencrypt"
    echo
    if ! seedbox_ask_domain "$ip" change; then
        WENT_BACK=1
        return 0
    fi
    if ((OPT_STAGING)); then server=staging; else server=production; fi
    echo
    if ((had_letsencrypt)); then
        if [[ $SEEDBOX_LETSENCRYPT != no ]] && tls_acme_usable "$LETSENCRYPT_DIR/cert.pem" "$SEEDBOX_DOMAIN" "$server"; then
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

# Said before removing the seedbox and before a restore: the account of the
# SFTP goes away (or comes back) meanwhile, and a WinSCP or FileZilla left open
# tries again every few seconds. fail2ban counts each try as a failure (it
# reads them again when it starts) and bans the address: every SSH session
# from there is cut.
sftp_programs_warning() {
    t 'Close WinSCP / FileZilla first: their automatic reconnections would be counted as failed logins, and fail2ban could ban your address.'
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
        warn 'fail2ban is not running: bans could not be checked.   → seedtunnel doctor'
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

# fail2ban_unban IP — an address fail2ban does not ban is said, nothing done
fail2ban_unban() {
    local ip=$1 jails
    is_ipv4 "$ip" || is_ipv6 "$ip" || die 'Invalid IP address: "%s"' "$ip"
    # the jails that ban it: « [['sshd', 'recidive']] », none: « [[]] »
    jails=$(fail2ban-client banned "$ip" 2>>"$APP_LOG") \
        || die 'fail2ban does not answer (details in %s)   → sudo systemctl status fail2ban' "$APP_LOG"
    if [[ $jails != *[A-Za-z]* ]]; then
        warn '%s is not banned right now: nothing to do.' "$ip"
        return 0
    fi
    run "$(t 'Unbanning %s' "$ip")" fail2ban-client unban "$ip"
    run "$(t 'Checking that %s stays unbanned' "$ip")" fail2ban_unban_settle "$ip"
    # fail2ban keeps counting the failures it saw (unban does not reset them)
    say 'Careful: fail2ban still counts the failures of the last 10 minutes: a few more mistakes within these 10 minutes ban %s again.' "$ip"
}

# Seconds before checking that an address just unbanned stays so (tests: 0)
FAIL2BAN_SETTLE_DELAY=${FAIL2BAN_SETTLE_DELAY:-2}

# fail2ban_unban_settle IP — recidive reads the bans of the other jails in the
# log of fail2ban a moment after they are made: an address unbanned right
# after its ban could be banned again by it, for a week. Checked a little
# later (3 times at most) and unbanned again. Status 1: still banned.
fail2ban_unban_settle() {
    local ip=$1 jails try
    for try in 1 2 3; do
        sleep "$FAIL2BAN_SETTLE_DELAY"
        jails=$(fail2ban-client banned "$ip") || return 1
        [[ $jails == *[A-Za-z]* ]] || return 0
        printf 'try %s: banned again (%s), unbanned again\n' "$try" "$jails"
        fail2ban-client unban "$ip" || return 1
    done
    sleep "$FAIL2BAN_SETTLE_DELAY"
    jails=$(fail2ban-client banned "$ip") || return 1
    [[ $jails != *[A-Za-z]* ]]
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
        if is_ipv4 "$ip" || is_ipv6 "$ip"; then break; fi
        warn 'Invalid IP address: "%s"' "$ip"
    done
    ui_paragraph "$(t 'This unbans %s in all fail2ban jails.' "$ip")"
    if confirm 'Unban this address?' n; then
        fail2ban_unban "$ip"
        pause
    fi
}

seedbox_restart() {
    local service
    echo
    for service in nginx fail2ban; do
        run "$(t 'Restarting %s' "$service")" systemctl restart "$service"
    done
    local OPERATION_FD=${OPERATION_FD-} _seedbox_restart_owner=""
    operation_begin _seedbox_restart_owner || return $?
    if restore_interrupted; then
        warn 'Engine restart suspended: a restore is unfinished.'
    elif diskguard_state_invalid; then
        warn 'Invalid disk guard record %s; automatic restart suspended.' "$DISKGUARD_MARKER"
    elif diskguard_restart_unconfirmed; then
        warn 'Automatic restart of %s could not be confirmed; disk guard state kept.' "$(engine_display_name)"
    elif diskguard_start_failed; then
        warn '%s does not start again although there is room (%s GB free):  journalctl -u %s -n 30' \
            "$(engine_display_name)" "$(disk_free_gb "$SEEDBOX_DATA_DIR")" "$(engine_service_name)"
    elif diskguard_stopped; then
        warn 'Transmission stays stopped: the disk is almost full (%s GB free). It restarts by itself above %s GB.' \
            "$(disk_free_gb "$SEEDBOX_DATA_DIR")" "$DISKGUARD_START_ABOVE_GB"
    else
        run "$(t 'Restarting %s' "$(engine_service_name)")" engine_restart
    fi
    operation_end "$_seedbox_restart_owner"
}

# Deletes the seedbox account, after closing its open SFTP sessions (they
# prevent the deletion). Stops the script if the account is still there.
seedbox_delete_user() {
    [[ -n $SEEDBOX_USER ]] && id "$SEEDBOX_USER" &>/dev/null || return 0
    log_title 'Deleting the user %s' "$SEEDBOX_USER"
    # the documents stay readable by root once the user is deleted
    if [[ -d $SEEDBOX_DATA_DIR/documents && ! -L $SEEDBOX_DATA_DIR/documents ]]; then
        seedbox_documents_owner root:root "$SEEDBOX_USER"
    fi
    if accounts_delete "$SEEDBOX_USER"; then return 0; fi
    die 'Cannot delete the user %s (details in %s). The seedbox was not removed and its SFTP restrictions stay in place: run the removal again.' \
        "$SEEDBOX_USER" "$APP_LOG"
}

# seedbox_delete_data DIR — the folders seedtunnel created in the data folder,
# then this folder if nothing else is left in it: a folder chosen before the
# check of its content, or filled by hand since, keeps the rest. Never on a
# disk mounted inside (the deletion then stops, said).
seedbox_delete_data() {
    local dir=$1 part
    local -a parts=()
    for part in "${STORAGE_PARTS[@]}"; do
        if [[ -e $dir/$part || -L $dir/$part ]]; then parts+=("$dir/$part"); fi
    done
    if ((${#parts[@]})); then run 'Deleting the data' rm -rf --one-file-system -- "${parts[@]}"; fi
    rmdir -- "$dir" 2>/dev/null || true
    if [[ -e $dir || -L $dir ]]; then warn 'Folder %s kept: it holds files that seedtunnel did not create.' "$dir"; fi
}

seedbox_uninstall() {
    local delete_data=0 note help
    local -a lines=()
    banner
    section 'Remove the seedbox'
    # the last part removed: the weekly backup and its passphrase go too
    note=$(backup_removal_note vpn)
    # one paragraph, cut again to the width of the window (the names of the
    # user and of the folder have any length)
    help=$(text seedbox_uninstall_help | tr '\n' ' ')
    help=${help% }
    if ((INTERACTIVE)); then lines+=("$help"); fi
    if [[ -n $note ]]; then lines+=("$note"); fi
    lines+=("$(sftp_programs_warning)")
    if ((!INTERACTIVE)); then
        ui_width
        ui_print_wrapped "" "" "$help"
        echo
    fi
    danger "$(t 'Remove the seedbox')" "${lines[@]}"
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
    local OPERATION_FD=${OPERATION_FD-} _seedbox_remove_owner=""
    operation_begin _seedbox_remove_owner || return $?
    seedbox_delete_user
    diskguard_remove
    log_run 'Stopping Transmission' engine_disable
    if [[ -f $SSHD_SEEDBOX_CONF ]]; then
        rm -f "$SSHD_SEEDBOX_CONF"
        run 'Reloading SSH' systemctl try-reload-or-restart ssh.service
    fi
    pending_clear ssh
    pending_clear nginx
    # under titles of their own in the log: their lines are not read as those
    # of the step before
    web_letsencrypt_delete
    log_run 'Stopping the download links in progress' systemctl stop 'seedtunnel-share-*'
    rm -rf "$SHARE_DIR" "$SHARE_DIR.jobs"
    rm -f "$NGINX_SITE_LINK" "$NGINX_SITE" "$NGINX_HTPASSWD"
    engine_remove_override
    # fail2ban stays for the VPN (its jail of the web interface goes below)
    if ! vpn_installed; then rm -f "$FAIL2BAN_JAIL" "$FAIL2BAN_MAIN_CONF"; fi
    rm -f "$SFTP_KEYS_DIR/$SEEDBOX_USER"
    rmdir "$SFTP_KEYS_DIR" 2>/dev/null || true
    seedbox_remove_apparmor
    rm -rf "$WEB_SSL_DIR" "$LETSENCRYPT_WEBROOT"
    systemctl daemon-reload 2>/dev/null || true
    engine_purge_packages nginx nginx-common certbot inotify-tools putty-tools
    if ! vpn_installed; then
        apt_purge fail2ban
        # installed for fail2ban; on its own: if another program needs it,
        # only it is kept
        apt_purge python3-systemd
    fi
    if ((delete_data)) && [[ -n $SEEDBOX_DATA_DIR && $SEEDBOX_DATA_DIR != / ]]; then
        seedbox_delete_data "$SEEDBOX_DATA_DIR"
    fi
    rm -f "$SEEDBOX_CONF_FILE" "$SEEDBOX_SECRETS_FILE"
    # without the jail of the web interface, now that the seedbox is gone
    if vpn_installed; then fail2ban_apply; fi
    net_hardening_cleanup
    login_alerts_cleanup
    firewall_refresh
    backup_auto_stop_if_unused
    operation_end "$_seedbox_remove_owner" || return 1
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
    ui_paragraph "$(t 'Restarting the seedbox services interrupts active connections.')"
    if confirm 'Restart the seedbox services?' n; then
        seedbox_restart
        pause
    fi
}

# The state of the seedbox, at the top of its menu
seedbox_menu_fields() {
    local certificate motor
    local -A observation=()
    seedbox_observe observation
    if [[ $SEEDBOX_CERTIFICATE == selfsigned ]]; then
        certificate="$C_YELLOW$(t 'self-signed')$C_RESET $(t "(option 2 to try Let's Encrypt again)")"
    else
        certificate=$(seedbox_certificate_label)
    fi
    motor=$(service_observed_short "${observation[engine_state]}")
    if [[ ${observation[restore_hold]:-no} == yes ]]; then
        motor="$C_YELLOW● $(t 'restore unfinished')$C_RESET"
    elif [[ ${observation[disk_state_invalid]:-no} == yes ]]; then
        motor="$C_YELLOW● $(t 'guard state invalid')$C_RESET"
    elif [[ ${observation[disk_resume_unknown]:-no} == yes ]]; then
        motor="$C_YELLOW● $(t 'restart unconfirmed')$C_RESET"
    elif [[ ${observation[disk_resume_failed]:-no} == yes ]]; then
        motor="$C_RED● $(t 'restart failed')$C_RESET"
    elif [[ ${observation[disk_halt]} == yes ]]; then motor="$C_RED● $(t 'stopped: disk almost full')$C_RESET"; fi
    ui_field_add "$(t 'Web interface')" "${C_CYAN}https://$SEEDBOX_DOMAIN/$C_RESET"
    ui_field_add "$(t 'Certificate')" "$certificate"
    ui_field_add SFTP "$SEEDBOX_USER@$SEEDBOX_DOMAIN · $(disk_free_text "$SEEDBOX_DATA_DIR")"
    ui_field_add "$(t 'SFTP password')" "$(sftp_password_state)"
    # full names, short states: the line fits in 80 columns. A green dot alone:
    # it runs; a red dot with a word: it does not (readable without colors too)
    ui_field_add Services "${observation[engine_name]} $motor · nginx $(service_observed_short "${observation[nginx_state]}") · fail2ban $(service_observed_short "${observation[fail2ban_state]}")"
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
        ui_menu_add 1 "$(t 'Seedbox credentials (web / SFTP)')"
        ui_menu_add 2 "$(t 'Domain name and HTTPS certificate')"
        ui_menu_add 3 "$(t 'SFTP access and client profiles')"
        ui_menu_gap
        ui_menu_add 4 "$(t 'Restart the services')"
        ui_menu_add 5 "$(t 'Remove the seedbox')"
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action access_credentials_menu ;;
            2) ui_action seedbox_menu_domain ;;
            3) ui_action access_sftp_menu ;;
            4) ui_action seedbox_menu_restart ;;
            5) ui_action seedbox_uninstall ;;
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
    case "$command ${1-}" in
        "sftp-key add" | "sftp-key remove") cli_takes 2 "seedbox $command ${1-}" "$@" ;;
        "sftp-key "*) cli_takes 1 "seedbox $command${1:+ $1}" "$@" ;;
        install\ * | password\ * | bans\ * | restart\ * | uninstall\ *) cli_takes 0 "seedbox $command" "$@" ;;
        domain\ * | sftp-config\ * | sftp-password\ * | unban\ *) cli_takes 1 "seedbox $command" "$@" ;;
    esac
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
            [[ -n ${1-} ]] || die 'Usage: seedtunnel seedbox unban IP'
            fail2ban_unban "$1"
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

# Seedbox-owned adapters to the shared web service.
seedbox_apply_nginx() {
    web_nginx_apply nginx_generate_site "$SEEDBOX_DOMAIN" "$SEEDBOX_CERTIFICATE"
}

seedbox_apply_https() {
    web_https_apply "$SEEDBOX_DOMAIN" "$SEEDBOX_LETSENCRYPT" "$SEEDBOX_LETSENCRYPT_SERVER" \
        SEEDBOX_CERTIFICATE nginx_generate_site "seedtunnel seedbox domain $SEEDBOX_DOMAIN"
}

# Own-context adapters to the selected download engine.
seedbox_apply_transmission() {
    local status
    # the status: see the contract at the top of engine.sh
    engine_configure "$SEEDBOX_DATA_DIR" "$SEEDBOX_USER" "$SEEDBOX_HASH_TRANSMISSION" \
        diskguard_stopped "$SEEDBOX_ENGINE_IMPORT_FROM" seedbox_import_engine
    status=$?
    if ((status)); then return "$status"; fi
    SEEDBOX_ENGINE_IMPORT_FROM=""
}

# Context adapter called only while engine_configure has the daemon stopped.
seedbox_import_engine() {
    engine_import "$1" "$SEEDBOX_DATA_DIR" "$RESTORE_MAGNETS_FILE" SEEDBOX_ENGINE_IMPORT_RESULT
}

seedbox_apply_apparmor() {
    engine_apply_confinement "$SEEDBOX_DATA_DIR"
}

seedbox_remove_apparmor() {
    engine_remove_confinement "$SEEDBOX_DATA_DIR"
}

# Own-context adapters for storage and human-account operations.
seedbox_default_data_dir() { storage_default_dir; }
seedbox_check_data_dir() { storage_check_chroot_path "$1" && storage_check_data_content "$1"; }
seedbox_apply_dirs() {
    storage_apply "$SEEDBOX_DATA_DIR" "$SEEDBOX_USER" "$(engine_account)" "$(engine_group)"
}
seedbox_documents_owner() {
    storage_documents_owner "$SEEDBOX_DATA_DIR" "$1" "$2"
}
seedbox_user_suspend() { accounts_suspend "${1:-$SEEDBOX_USER}"; }
seedbox_user_resume() { accounts_resume "${1:-$SEEDBOX_USER}"; }

# SFTP adapters supply only their own feature context.
seedbox_sshd_settings() { sftp_effective_settings "$SEEDBOX_USER" "$1"; }
seedbox_sftp_rule_applies() {
    sftp_rule_applies "$SEEDBOX_USER" "$SEEDBOX_DATA_DIR" "$SEEDBOX_SFTP_PASSWORD" \
        "$SFTP_KEYS_DIR" 127.0.0.1 "$VPN_SUBNET.2" 203.0.113.1
}
seedbox_rename_account() { sftp_rename_account "$1" "$2" "$SFTP_KEYS_DIR"; }
sshd_generate_seedbox_conf() {
    sftp_generate_conf "$SEEDBOX_USER" "$SEEDBOX_DATA_DIR" "$SEEDBOX_SFTP_PASSWORD" "$SFTP_KEYS_DIR"
}
seedbox_apply_sftp() {
    sftp_apply "$SEEDBOX_USER" "$SEEDBOX_DATA_DIR" SEEDBOX_SFTP_PASSWORD \
        "$SFTP_KEYS_DIR" "$SSHD_SEEDBOX_CONF" 127.0.0.1 "$VPN_SUBNET.2" 203.0.113.1
}

# Key/profile adapters: select seedbox context and keep presentation here.
sftp_has_seedtunnel_key() { sftp_account_has_generated_key "$SEEDBOX_USER" "$SFTP_KEYS_DIR"; }
sftp_keys_count() { sftp_account_keys_count "$SEEDBOX_USER" "$SFTP_KEYS_DIR"; }
sftp_keys_import() {
    local added=0
    # the status: see the contract at the top of engine.sh
    sftp_account_keys_import "$SEEDBOX_USER" "$SFTP_KEYS_DIR" "$1" added
    local status=$?
    if ((status)); then return "$status"; fi
    if ((added)); then
        ok '%s SSH key(s) added for %s.' "$added" "$SEEDBOX_USER"
    else
        ok 'Key(s) already saved for %s.' "$SEEDBOX_USER"
    fi
}
host_key_fingerprint() { ssh_host_key_fingerprint /etc/ssh/ssh_host_ed25519_key.pub; }
host_key_fingerprint_url() { ssh_host_key_fingerprint_url /etc/ssh/ssh_host_ed25519_key.pub; }
winscp_url() {
    sftp_winscp_url "$SEEDBOX_USER" "$SEEDBOX_DOMAIN" "$1" "$(host_key_fingerprint_url)"
}
filezilla_generate_site() {
    sftp_filezilla_site "$SEEDBOX_USER" "$SEEDBOX_DOMAIN" "$1" "Seedbox $SEEDBOX_DOMAIN"
}
winscp_generate_site() {
    local key_name=""
    if sftp_has_seedtunnel_key; then key_name="seedbox-$SEEDBOX_USER.ppk"; fi
    sftp_winscp_site "$SEEDBOX_USER" "$SEEDBOX_DOMAIN" "$1" "Seedbox $SEEDBOX_DOMAIN" \
        "$(host_key_fingerprint_url)" "$key_name"
}

# Own-context adapters for the common disk guard. Environment overrides are
# retained for integration tests; ExecStartPre never waits on an operation.
diskguard_prestart() {
    (
        # After interruption/reboot there is no active repair scope. Refuse to
        # start partial state; a live coordinator is allowed to finish its work.
        if restore_interrupted && ! operation_in_progress; then
            warn 'Engine start refused: a restore is unfinished and no active operation could be confirmed.'
            return 1
        fi
        seedbox_load || return $?
        seedbox_installed || return 0
        diskguard_prestart_for "$SEEDBOX_DATA_DIR" "$DISKGUARD_MARKER" \
            "${SEEDTUNNEL_DISKGUARD_STOP_BELOW_GB:-$DISKGUARD_STOP_BELOW_GB}" "$(engine_display_name)"
    )
}
# A subprocess bounds the timer's descriptor and reloaded feature variables.
diskguard_check() { (diskguard_check_locked); }

diskguard_check_locked() {
    # A timer always contends independently, even if invoked from a scope.
    local OPERATION_FD="" _guard_owner="" _guard_status=0
    operation_begin _guard_owner try || _guard_status=$?
    if ((_guard_status == 75)); then return 0; fi
    if ((_guard_status)); then return "$_guard_status"; fi
    if restore_interrupted; then
        operation_end "$_guard_owner"
        return $?
    fi
    seedbox_load
    if seedbox_installed; then
        # the status: see the contract at the top of engine.sh
        diskguard_check_for "$SEEDBOX_DATA_DIR" "$DISKGUARD_MARKER" \
            "${SEEDTUNNEL_DISKGUARD_STOP_BELOW_GB:-$DISKGUARD_STOP_BELOW_GB}" \
            "${SEEDTUNNEL_DISKGUARD_START_ABOVE_GB:-$DISKGUARD_START_ABOVE_GB}" \
            "$(engine_display_name)" "$(engine_service_name)" engine_start engine_stop engine_runtime_state
        _guard_status=$?
    fi
    operation_end "$_guard_owner" || return 1
    return "$_guard_status"
}
