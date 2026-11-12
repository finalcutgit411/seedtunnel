#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — one-time download links
#
#  To get a file (VPN configuration, FileZilla site, backup) onto a computer
#  without scp: the HTTPS site of the seedbox serves
#  https://<domain>/share/<token>/, a page with a download button. The token
#  is random (128 bits): impossible to guess. With the VPN alone, a small
#  HTTPS site that serves the links and nothing else (see « Site of the links »
#  below).
#
#  nginx serves the file of a link once: any other request on it is refused on
#  the spot (even right after, on the same connection, or with another form of
#  the address), never a partial download, and a HEAD request is refused
#  without using the link up. The file is also deleted the moment nginx opens
#  it (inotify). An unused link expires after 10 minutes. Everything lives in
#  /run, which is emptied at boot.
#  Opening the page does not count: a messaging app that previews the link
#  does not use it up.
# =============================================================================

SHARE_DIR="/run/seedtunnel-share"
SHARE_URL_PATH="/share"
SHARE_LIFETIME=600

# Watches one link (started on its own by systemd-run): waits for the first
# opening of the file, or the end of the lifetime, then deletes the link.
# If a mark file is given, it is touched when the file was really opened.
#   $1 job file of root: folder of the link, name of the file, lifetime
#      (seconds), mark file, one per line (deleted afterwards by JOB.stop,
#      run by systemd when the watcher ends, whatever ends it)
# The token is in no argument: the arguments of every command can be read by
# every account of the server (ps, systemctl status), and the token is the
# password of the link. inotifywait watches « ./NAME » from the folder.
read -r -d '' SHARE_WATCHER <<'SH' || true
{ IFS= read -r dir; IFS= read -r name; IFS= read -r lifetime; IFS= read -r mark; } <"$1" || exit 1
cd -- "$dir" || exit 1
if inotifywait -qq -t "$lifetime" -e open -- "./$name"; then
    if [[ -n $mark ]]; then touch -- "$mark"; fi
fi
cd /
rm -rf -- "$dir"
SH

# nginx directives at the top of the seedbox site (http level)
share_generate_nginx_http() {
    cat <<'EOF'
# One-time links (see the location /share/ below). The file of a link (never
# its page) is served once: any other request on it gets a 404 for a minute,
# and by then the file is long gone. nginx decides it on the spot, so two
# requests one right after the other cannot both get the file.
map $uri $seedtunnel_share_file {
    # the page of the link, opened as often as needed (preview of a message)
    "~^/share/[0-9a-f]{32}/index\.html$" "";
    "~^/share/[0-9a-f]{32}/[^/]+$" $uri;
    default "";
}
limit_req_zone $seedtunnel_share_file zone=seedtunnel_share:1m rate=1r/m;
# Only GET gets the file: HEAD (or anything else) would open it, using the link
# up, without downloading it
map "$request_method $uri" $seedtunnel_share_refused {
    "~^GET " 0;
    "~^[^ ]+ /share/[0-9a-f]{32}/[^/]+$" 1;
    default 0;
}
# The token of a link is its password: the access log shows /share/<token>/…
# instead (the address, the time and the result stay)
map $request_uri $seedtunnel_share_logged {
    "~^/share/[0-9a-f]{32}(.*)$" "/share/<token>$1";
    default $request_uri;
}
log_format seedtunnel_share '$remote_addr - $remote_user [$time_local] '
    '"$request_method $seedtunnel_share_logged $server_protocol" $status $body_bytes_sent '
    '"$http_referer" "$http_user_agent"';
EOF
}

SHARE_GONE_PAGE="web/link-gone.html"

# A link used or expired (or a wrong token) answers 404 with a page that says
# so, in the colors of seedtunnel but without its name (like the page « access
# denied »: anyone can try an address under /share/). Only if the page is
# there: otherwise the 404 of nginx, as before.
# The page has the headers of the links and their access log: the address
# asked (with its token) is the one logged, even after the redirect to the page.
# $1: HSTS header, if any, already formatted.
share_generate_gone_page() {
    [[ -r $APP_DIR/$SHARE_GONE_PAGE ]] || return 0
    cat <<EOF

    location = /seedtunnel/link-gone.html {
        auth_basic off;
        internal;
        alias $APP_DIR/$SHARE_GONE_PAGE;
        default_type text/html;
        access_log /var/log/nginx/access.log seedtunnel_share;
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy no-referrer always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'" always;${1-}
    }
EOF
}

# nginx block inside the HTTPS server of the seedbox (see nginx_generate_site).
# $1: HSTS header, if any, already formatted.
share_generate_nginx() {
    local gone=""
    if [[ -r $APP_DIR/$SHARE_GONE_PAGE ]]; then
        gone=$'\n        # used, expired or unknown: a page that says so\n        error_page 404 /seedtunnel/link-gone.html;'
    fi
    cat <<EOF

    # One-time links (seedtunnel vpn share, seedbox sftp-config, backup share):
    # no password, the random token of the link plays that role
    location ^~ $SHARE_URL_PATH/ {
        auth_basic off;
        alias $SHARE_DIR/;
        access_log /var/log/nginx/access.log seedtunnel_share;
        log_not_found off;
        # the file: GET only, served once (see the top of the site), always
        # whole (no Range, no cache)
        if (\$seedtunnel_share_refused) {
            return 405;
        }
        limit_req zone=seedtunnel_share;
        limit_req_status 404;$gone
        max_ranges 0;
        open_file_cache off;
        if_modified_since off;
        etag off;
        types {
            text/html html;
        }
        default_type application/octet-stream;
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy no-referrer always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'" always;${1-}
    }$(share_generate_gone_page "${1-}")
EOF
}

# Links go through an HTTPS site, which must be running: the one of the
# seedbox or, with the VPN alone, the site of the links (offered the first
# time). Status 1 if it is declined: $1 (translated), what to do instead, is
# said.
share_require() {
    if seedbox_installed; then
        systemctl is-active --quiet nginx || die 'nginx is stopped:  seedtunnel seedbox restart'
        return 0
    fi
    vpn_installed || die 'Download links go through an HTTPS site: the one of the seedbox, or the site of the links of the VPN. Neither is installed.\n  %s' "$1"
    links_load
    if links_site_on; then
        systemctl is-active --quiet nginx || die 'nginx is stopped:  seedtunnel vpn links on'
        return 0
    fi
    links_offer "$1"
}

# --- Site of the links (VPN without a seedbox) ---------------------------------------
# A small HTTPS site that serves the links and nothing else: any other address
# answers 404, and it asks for no password (the token of a link plays that
# role). Its name is the address of the VPN; it uses the nginx, the paths and
# the certificates of the seedbox (Let's Encrypt for a domain name pointing to
# this server, self-signed otherwise), through links_run.
# Offered at the first link; removed with « seedtunnel vpn links off » or with
# the VPN. A seedbox installed afterwards takes its place (its own site serves
# the links), and removing that seedbox removes it: offered again at the next
# link.
LINKS_CONF_FILE="$APP_STATE_DIR/links.conf"
# selfsigned | letsencrypt: certificate served right now
LINKS_CERTIFICATE="selfsigned"

links_load() {
    LINKS_CERTIFICATE="selfsigned"
    state_read "$LINKS_CONF_FILE"
}

links_save() { state_write "$LINKS_CONF_FILE" LINKS_CERTIFICATE; }

# Is the site of the links there? (a seedbox takes its place)
links_site_on() { [[ -f $LINKS_CONF_FILE ]] && ! seedbox_installed; }

# Name of the site that serves the links: the one of the seedbox, or the
# address of the VPN
share_site_domain() {
    if seedbox_installed; then printf '%s' "$SEEDBOX_DOMAIN"; else printf '%s' "${VPN_PUBLIC_ADDRESS,,}"; fi
}

# Certificate of that site (selfsigned | letsencrypt | staging)
share_site_certificate() {
    if seedbox_installed; then printf '%s' "$SEEDBOX_CERTIFICATE"; else printf '%s' "$LINKS_CERTIFICATE"; fi
}

# links_run COMMAND… — a function of the seedbox (certificate, nginx) for the
# site of the links: with its name, its certificate and its own nginx site,
# in the variables of the seedbox for this call only. The certificate chosen
# comes back in LINKS_CERTIFICATE. Never a test server of Let's Encrypt here.
links_run() {
    local SEEDBOX_DOMAIN=${VPN_PUBLIC_ADDRESS,,} SEEDBOX_CERTIFICATE=$LINKS_CERTIFICATE \
        SEEDBOX_LETSENCRYPT=auto SEEDBOX_LETSENCRYPT_SERVER=production NGINX_SITE_GENERATOR=links_generate_site
    "$@"
    LINKS_CERTIFICATE=$SEEDBOX_CERTIFICATE
}

# nginx site of the links (through links_run: SEEDBOX_DOMAIN is the address
# of the VPN): HTTP for Let's Encrypt then to HTTPS, and in HTTPS the links
# only
links_generate_site() {
    local hsts ipv6_80="" ipv6_443=""
    hsts=$(nginx_generate_hsts)
    if [[ -e /proc/net/if_inet6 ]]; then
        ipv6_80=$'\n    listen [::]:80;'
        ipv6_443=$'\n    listen [::]:443 ssl;'
    fi
    cat <<EOF
# Written by seedtunnel — site of the one-time links of the VPN (no seedbox).
# Use the menu rather than editing this file.

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
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;$hsts
$(share_generate_nginx "${hsts//$'\n    '/$'\n        '}")

    # nothing else here
    location / {
        return 404;
    }
}
EOF
}

# The address of the VPN as the name of a site: an IPv4 address or a domain
# name (an IPv6 address would need links and a certificate of its own)
links_check_address() {
    if is_ipv6 "$VPN_PUBLIC_ADDRESS"; then
        die 'The address of the VPN is an IPv6 address (%s): the site of the links needs an IPv4 address or a domain name   → VPN, « Change the address or the port »' "$VPN_PUBLIC_ADDRESS"
    fi
}

# Puts the site of the links in the state of its settings (idempotent): at its
# installation, and again with « seedtunnel apply », a new address of the VPN
# or a restore
links_apply() {
    local -a packages=(nginx bind9-dnsutils inotify-tools)
    links_check_address
    links_load
    # certbot for a domain name only: an IP address gets a self-signed certificate
    if ! is_ipv4 "$VPN_PUBLIC_ADDRESS"; then packages+=(certbot); fi
    apt_install "${packages[@]}"
    # its settings first: the firewall opens 80 and 443 for it, before the
    # request to Let's Encrypt
    links_save
    firewall_refresh
    links_run seedbox_apply_https
    links_save
}

# links_install — the site of the links, the first time
links_install() {
    links_check_address
    seedbox_check_web_ports links
    echo
    log_title 'Site of the links'
    links_apply
    ok 'Site of the links installed.'
}

# What the site of the links is, before it is installed
links_site_help() {
    local address=${VPN_PUBLIC_ADDRESS,,} certificate
    if is_ipv4 "$address"; then
        certificate=$(t 'self-signed (IP address): the browser shows a warning, and each link gives the fingerprint to check before accepting it')
    else
        certificate=$(t "Let's Encrypt if %s points to this server, otherwise self-signed (browser warning, and each link gives the fingerprint to check)" "$address")
    fi
    ui_paragraph "$(t 'Download links go through an HTTPS site. Without a seedbox, seedtunnel can put a small one on this server: nginx on ports 80 and 443, for the links only, and nothing else.')"
    echo
    ui_field_add "$(t 'Address')" "${C_CYAN}https://$address$SHARE_URL_PATH/…$C_RESET"
    ui_field_add "$(t 'Certificate')" "$certificate"
    ui_field_add "$(t 'Removal')" "$(t 'VPN menu → « Site of the links », or  seedtunnel vpn links off')"
    ui_fields_show
}

# links_offer HINT — VPN alone, no site for the links yet: what it is, then
# the question. Status 1 if the answer is no: HINT (translated) says what to
# do instead.
links_offer() {
    links_site_help
    echo
    if ! confirm 'Install the site of the links? (opens ports 80 and 443)' y; then
        echo
        printf '  %s\n' "$1"
        return 1
    fi
    links_install
}

# links_remove — the site of the links goes, with the links in progress and
# what it alone installed (nginx, certbot…: only if seedtunnel installed
# them). With a seedbox, its settings only: the site is the seedbox's.
links_remove() {
    [[ -f $LINKS_CONF_FILE ]] || return 0
    if seedbox_installed; then
        rm -f "$LINKS_CONF_FILE"
        return 0
    fi
    log_title 'Removing the site of the links'
    log_run 'Stopping the download links in progress' systemctl stop 'seedtunnel-share-*'
    rm -rf "$SHARE_DIR" "$SHARE_DIR.jobs"
    seedbox_letsencrypt_delete
    rm -f "$NGINX_SITE_LINK" "$NGINX_SITE" "$LINKS_CONF_FILE"
    rm -rf "$SEEDBOX_SSL_DIR" "$LETSENCRYPT_WEBROOT"
    pending_clear nginx
    apt_purge nginx nginx-common certbot inotify-tools
    # an nginx installed before seedtunnel stays: without this site
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_run 'Reloading nginx' systemctl reload nginx
    fi
    firewall_refresh
}

# Safety net: link folders whose watcher has disappeared
share_purge() {
    local folder
    for folder in "$SHARE_DIR" "$SHARE_DIR.jobs"; do
        [[ -d $folder ]] || continue
        find "$folder" -mindepth 1 -maxdepth 1 -mmin +$((SHARE_LIFETIME / 60 + 5)) \
            -exec rm -rf {} + 2>/dev/null || true
    done
}

# French punctuation stays with its word in a page: « and the space after
# it, the space before » : ; ? ! become no-break spaces (like ui_glue in the
# terminal), so that a « never ends a line and a » never starts one
share_glue() {
    local text=$1 nbsp=$'\xc2\xa0' sign
    text=${text//"« "/"«$nbsp"}
    for sign in '»' ':' ';' '?' '!'; do
        text=${text//" $sign"/"$nbsp$sign"}
    done
    printf '%s' "$text"
}

# Home page of a link, in the colors of seedtunnel (dark, like the terminal):
# download button, single use, then how to use the file, numbered. Nothing
# fetched elsewhere (no font, no image, no script): the emblem is drawn in
# the page. Everything inserted here was checked before (names, domain): no
# HTML.
share_generate_page() {
    local name=$1 title=$2 steps=$3 note=$4 next="" file
    title=$(share_glue "$title")
    steps=$(share_glue "$steps")
    note=$(share_glue "$note $(t 'Opening this page does not use the link up: only the download does.')")
    file=$(share_glue "$(t 'File:')")
    if [[ -n $steps ]]; then
        next="<h2>$(t 'Next')</h2>
<ol>
$steps
</ol>"
    fi
    cat <<EOF
<!doctype html>
<html lang="$APP_LANG">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>$title</title>
<style>
html { color-scheme: dark; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #0f0e16; color: #e6e6e6; font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, "DejaVu Sans", sans-serif; }
main { box-sizing: border-box; width: min(560px, calc(100% - 32px)); margin: 32px 16px; padding: 36px 36px 30px; background: #16141f; border: 1px solid #2b2838; border-radius: 16px; box-shadow: 0 24px 60px rgba(0, 0, 0, .5); }
header { display: flex; align-items: center; gap: 14px; }
svg { flex: none; }
.brand { font-size: 13px; color: #8a8499; letter-spacing: .02em; }
.brand b { color: #f4f2f8; }
.brand span { color: #ff5fff; font-weight: 700; }
h1 { margin: 22px 0 6px; font-size: 22px; line-height: 1.3; }
.file { margin: 0; color: #8a8499; font-size: 14px; }
.file code { color: #5fd7d7; }
.button { display: block; margin: 22px 0 6px; padding: 14px 18px; border-radius: 10px; text-align: center; font-weight: 700; color: #fff; text-decoration: none; overflow-wrap: anywhere; background: linear-gradient(90deg, #af00af, #ff5fff); box-shadow: 0 8px 24px rgba(175, 0, 175, .35); }
.button:focus-visible { outline: 3px solid #ffd75f; outline-offset: 3px; }
.once { margin: 0 0 24px; text-align: center; font-size: 13px; color: #ffd75f; }
h2 { margin: 0 0 10px; font-size: 13px; text-transform: uppercase; letter-spacing: .08em; color: #8a8499; }
ol { list-style: none; counter-reset: step; margin: 0; padding: 0; display: grid; gap: 12px; }
ol li { counter-increment: step; position: relative; padding-left: 38px; }
ol li::before { content: counter(step); position: absolute; left: 0; top: 0; width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center; font-size: 13px; font-weight: 700; color: #ff5fff; border: 1.5px solid #ff5fff; box-sizing: border-box; }
code { background: #221f2d; color: #e8e6ef; padding: .1rem .35rem; border-radius: 5px; word-break: break-all; font-size: .92em; }
.note { margin: 24px 0 0; padding-top: 16px; border-top: 1px solid #2b2838; color: #8a8499; font-size: 14px; }
@media (max-width: 480px) { main { padding: 28px 22px 24px; } h1 { font-size: 20px; } }
</style>
</head>
<body>
<main>
<header>
<svg width="56" height="36" viewBox="0 6 28 18" aria-hidden="true"><rect x="1" y="7" width="26" height="16" rx="3" fill="none" stroke="#ff5fff" stroke-width="2"/><circle cx="8" cy="15" r="2.6" fill="#ff5fff"/><circle cx="20" cy="15" r="2.6" fill="#ff5fff"/><path d="M8 15h12" stroke="#ff5fff" stroke-width="2"/></svg>
<div class="brand"><b>Seed</b><span>Tunnel</span> · $(t 'download link')</div>
</header>
<h1>$title</h1>
<p class="file">$file <code>$name</code></p>
<a class="button" href="$name" download>$(t 'Download %s' "$name")</a>
<p class="once">$(t 'One time only · valid for %s minutes' "$((SHARE_LIFETIME / 60))")</p>
$next
<p class="note">$note</p>
</main>
</body>
</html>
EOF
}

# Is there room in /run (in memory, a small size) for a copy of FILE? A margin
# of 1 MB is kept for the rest of the system. Not measurable: it is tried.
share_room_for() {
    local size avail=""
    size=$(stat -c %s -- "$1")
    avail=$({ df -B1 --output=avail "${SHARE_DIR%/*}" 2>/dev/null || true; } | tail -n 1)
    [[ ! $avail =~ ^[0-9]+$ ]] || ((size + 1048576 <= avail))
}

# share_create FILE NAME "Title" "<li>steps…</li>" "Note" [MARK_FILE]
# Publishes FILE under the name NAME and prints the link.
share_create() {
    local source=$1 name=$2 title=$3 steps=$4 note=$5 mark=${6-} token dir id job unit i pid ready=0
    apt_install inotify-tools
    # the site must know /share/ (if it was installed by an older version)
    if seedbox_installed; then seedbox_apply_nginx; else links_run seedbox_apply_nginx; fi
    share_purge
    # links live in memory (/run): a big backup may not fit
    if ! share_room_for "$source"; then
        die 'Not enough room in %s (in memory) for a link to %s (%s): copy it with WinSCP or scp instead.' \
            "${SHARE_DIR%/*}" "$name" "$(human_size "$(stat -c %s -- "$source")")"
    fi
    # nginx goes through it, but cannot list the links in it
    install -d -m 710 -o root -g www-data "$SHARE_DIR"
    install -d -m 700 "$SHARE_DIR.jobs"
    token=$(openssl rand -hex 16)
    dir="$SHARE_DIR/$token"
    # a link prepared halfway (disk full…) is deleted: nothing stays behind
    if ! {
        install -d -m 750 -o root -g www-data "$dir" \
            && install -m 640 -o root -g www-data "$source" "$dir/$name" \
            && share_generate_page "$name" "$title" "$steps" "$note" >"$dir/index.html" \
            && chown root:www-data "$dir/index.html" && chmod 640 "$dir/index.html"
    } >>"$APP_LOG" 2>&1; then
        rm -rf "$dir"
        die 'Cannot prepare the link (disk full? details in %s).' "$APP_LOG"
    fi

    # the report (doctor.sh) finds the names of the VPN clients in this title
    log_title 'Download link for %s' "$name"
    # The watcher runs as a service of its own. Whatever ends it (download,
    # expiry, crash, killed), systemd deletes the link afterwards
    # (ExecStopPost); RuntimeMaxSec ends it at the latest after the lifetime.
    # Its name, its job file and its arguments have nothing of the token:
    # what it needs is in files of root only.
    id=$(openssl rand -hex 6)
    job="$SHARE_DIR.jobs/$id"
    unit="seedtunnel-share-$id"
    if ! {
        (umask 077 && printf '%s\n' "$dir" "$name" "$SHARE_LIFETIME" "$mark" >"$job") \
            && (umask 077 && printf 'rm -rf -- %q\nrm -f -- %q "$0"\n' "$dir" "$job" >"$job.stop")
    } 2>>"$APP_LOG"; then
        rm -rf "$dir" "$job" "$job.stop"
        die 'Cannot prepare the link (disk full? details in %s).' "$APP_LOG"
    fi
    # A second safety, apart from the watcher: whatever becomes of it, a timer
    # deletes the link at the end of its lifetime (after a watcher killed, a
    # recent systemd does not always run its ExecStopPost)
    if ! systemd-run --quiet --collect --unit="$unit" \
        --property=RuntimeMaxSec=$((SHARE_LIFETIME + 60)) \
        --property="ExecStopPost=-/bin/bash $job.stop" \
        /bin/bash -c "$SHARE_WATCHER" seedtunnel-share "$job" >>"$APP_LOG" 2>&1 \
        || ! systemd-run --quiet --collect --unit="$unit-end" --on-active=$((SHARE_LIFETIME + 120)) \
            /bin/sh -c 'if [ -e "$1" ]; then exec /bin/bash "$1"; fi' seedtunnel-share-end "$job.stop" >>"$APP_LOG" 2>&1; then
        systemctl stop "$unit" "$unit-end.timer" >>"$APP_LOG" 2>&1 || true
        rm -rf "$dir" "$job" "$job.stop"
        die 'Cannot start the watcher of the link (details in %s).' "$APP_LOG"
    fi
    # the watch must be in place before the link is shown: otherwise, no link
    for i in {1..50}; do
        pid=$(systemctl show --property=MainPID --value "$unit" 2>/dev/null || true)
        if [[ $pid =~ ^[1-9][0-9]*$ ]] && pgrep -P "$pid" -x inotifywait >/dev/null; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if ((!ready)); then
        systemctl stop "$unit" >>"$APP_LOG" 2>&1 || true
        rm -rf "$dir" "$job" "$job.stop"
        die 'The watcher of the link did not start (details in %s): link cancelled.' "$APP_LOG"
    fi
    sleep 0.2

    echo
    say 'Download link (%sone time only, for %s minutes%s):' "$C_BOLD" "$((SHARE_LIFETIME / 60))" "$C_RESET"
    printf '  %shttps://%s%s/%s/%s\n\n' "$C_BOLD" "$(share_site_domain)" "$SHARE_URL_PATH" "$token" "$C_RESET"
    if [[ $(share_site_certificate) == selfsigned ]]; then
        # a link may carry a private key: the warning is only accepted for
        # the right certificate, not blindly
        t 'Self-signed certificate: the browser shows a warning. Before accepting it, check that the certificate it shows has this SHA-256 fingerprint:' | ui_text
        share_print_fingerprint "$(seedbox_selfsigned_fingerprint)"
        echo
    fi
}

# share_print_fingerprint FINGERPRINT — indented; on two lines of 16 bytes
# when one line does not fit on the screen (95 characters: a terminal would
# cut it anywhere)
share_print_fingerprint() {
    if ((${#1} + 2 <= UI_WIDTH || ${#1} <= 48)); then
        printf '  %s\n' "$1"
    else
        printf '  %s\n  %s\n' "${1:0:48}" "${1:48}"
    fi
}
