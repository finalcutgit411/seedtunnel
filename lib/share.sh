#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — one-time download links
#
#  To get a file (VPN configuration, FileZilla site, backup) onto a computer
#  without scp: the HTTPS site of the seedbox serves
#  https://<domain>/share/<token>/, a page with a download button. The token
#  is random (128 bits): impossible to guess.
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

# nginx block inside the HTTPS server of the seedbox (see nginx_generate_site).
# $1: HSTS header, if any, already formatted.
share_generate_nginx() {
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
        limit_req_status 404;
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
    }
EOF
}

# Links go through the seedbox site: it must be installed and running.
# $1: what to do instead, without a seedbox.
share_require() {
    seedbox_installed || die 'Download links go through the HTTPS site of the seedbox, which is not installed.\n  %s' "$1"
    systemctl is-active --quiet nginx || die 'nginx is stopped:  seedtunnel seedbox restart'
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

# Home page of a link: download button + how to use the file.
# Everything inserted here was checked before (names, domain): no HTML.
share_generate_page() {
    local name=$1 title=$2 steps=$3 note=$4
    cat <<EOF
<!doctype html>
<html lang="$APP_LANG">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>$title</title>
<style>
body { font: 16px/1.55 system-ui, sans-serif; max-width: 34rem; margin: 2.5rem auto; padding: 0 1rem; color: #1f2328; background: #f6f8fa; }
h1 { font-size: 1.35rem; }
.button { display: inline-block; margin: .5rem 0 1rem; padding: .75rem 1.3rem; border-radius: .5rem; background: #1f6feb; color: #fff; font-weight: 600; text-decoration: none; }
li { margin: .35rem 0; }
code { background: #eaeef2; padding: .1rem .3rem; border-radius: .25rem; word-break: break-all; }
.note { color: #57606a; font-size: .92rem; }
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; background: #0d1117; }
  code { background: #2d333b; }
  .note { color: #8d96a0; }
}
</style>
</head>
<body>
<h1>$title</h1>
<a class="button" href="$name" download>$(t 'Download %s' "$name")</a>
<ol>
$steps
</ol>
<p class="note">$note $(t 'This link works only once and expires after %s minutes.' "$((SHARE_LIFETIME / 60))")</p>
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
    seedbox_apply_nginx
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
    printf '  %shttps://%s%s/%s/%s\n\n' "$C_BOLD" "$SEEDBOX_DOMAIN" "$SHARE_URL_PATH" "$token" "$C_RESET"
    if [[ $SEEDBOX_CERTIFICATE == selfsigned ]]; then
        # a link may carry a private key: the warning is only accepted for
        # the right certificate, not blindly
        say 'Self-signed certificate: the browser shows a warning. Before accepting it, check that the certificate it shows has this SHA-256 fingerprint:'
        printf '  %s\n' "$(seedbox_selfsigned_fingerprint)"
        echo
    fi
}
