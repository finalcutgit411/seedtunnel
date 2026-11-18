#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Transmission adapter: owned paths, JSON, confinement and application.
# Load after common/network; no feature state is read at source time.
# Configure inputs: DATA RPC_USER RPC_HASH BLOCKED_QUERY RESTORE_SOURCE CALLBACK.
# Hashes enter jq through its environment, never an external command argument.

TRANSMISSION_DROPIN="/etc/systemd/system/transmission-daemon.service.d/seedtunnel.conf"
TRANSMISSION_USER="debian-transmission"
TRANSMISSION_STATE_DIR="/var/lib/transmission-daemon/.config/transmission-daemon"
TRANSMISSION_ETC_SETTINGS="/etc/transmission-daemon/settings.json"
TRANSMISSION_RPC_PORT=9091
TORRENT_PORT=60000
TRANSMISSION_APPARMOR_PROFILE="/etc/apparmor.d/transmission"
TRANSMISSION_APPARMOR_LOCAL="/etc/apparmor.d/local/transmission-daemon"
APPARMOR_ENABLED_FILE="/sys/module/apparmor/parameters/enabled"
TRANSMISSION_UMASK_JQ='def umask_value: if type == "number" then . elif type == "string" and $text_ok and test("^[0-7]+$") then (explode | map(. - 48) | reduce .[] as $x (0; . * 8 + $x)) else -1 end;'
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
  "script-torrent-done-enabled": false,
  "script-torrent-done-filename": "",
  "umask": 2
}
JQ

# Real settings file of Transmission: the one in /etc that the link of Debian
# points to, or a file of its own in its folder. Nothing else: the account of
# Transmission can change this link (its folder belongs to it), and root would
# then read, write and back up the file it points to. Status 1 otherwise.
# Without the link, the file of /etc, never a link either: its folder can be
# written by the group of Transmission.
transmission_settings_file() {
    local link="$TRANSMISSION_STATE_DIR/settings.json" real
    if [[ ! -e $link && ! -L $link ]]; then
        if [[ -L $TRANSMISSION_ETC_SETTINGS || (-e $TRANSMISSION_ETC_SETTINGS && ! -f $TRANSMISSION_ETC_SETTINGS) ]]; then
            err 'The settings of Transmission %s are not a file (a link?): seedtunnel does not follow it   → rm %s, then seedtunnel apply' \
                "$TRANSMISSION_ETC_SETTINGS" "$TRANSMISSION_ETC_SETTINGS"
            return 1
        fi
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

# transmission_settings_read FILE — the settings of Transmission, read by its
# own account, never by root: where it could lead root with a link, it can
# only read what it can read already
transmission_settings_read() {
    runuser -u "$TRANSMISSION_USER" -- cat -- "$1"
}

# transmission_settings_write FILE SOURCE — the settings of Transmission
# replaced by those of SOURCE, written by the account of Transmission, never
# by root: a link it put in its folders could only lead it where it can write
# already. Replaced by renaming, never half-written, readable by it alone.
transmission_settings_write() {
    runuser -u "$TRANSMISSION_USER" -- sh -c 'umask 077 && cat >"$1.new" && mv -f "$1.new" "$1"' sh "$1" <"$2"
}

# transmission_make_private SETTINGS — its settings (hash of the password) and
# its folder (torrents, names of the downloads) closed to the other accounts.
# By its own account, for the same reason: it can only change its own files.
transmission_make_private() {
    runuser -u "$TRANSMISSION_USER" -- chmod 600 -- "$1" >>"$APP_LOG" 2>&1 || true
    if [[ -d $TRANSMISSION_STATE_DIR ]]; then
        runuser -u "$TRANSMISSION_USER" -- chmod o-rwx -- "$TRANSMISSION_STATE_DIR" >>"$APP_LOG" 2>&1 || true
    fi
}

# web_check_ports [links] — no other program on 80 or 443 (links:
# for the site of the links)
# shellcheck disable=SC2120 # « links » comes from lib/share.sh and lib/backup.sh

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

transmission_apparmor_confined() {
    [[ -f $TRANSMISSION_APPARMOR_PROFILE ]] && grep -q 'local/transmission-daemon' "$TRANSMISSION_APPARMOR_PROFILE" 2>/dev/null
}

# The rules for the data folder (quoted: a path may hold a space)
transmission_apparmor_generate() {
    local data_dir=$1
    local dir
    dir=$(realpath -m "$data_dir")
    printf '%s\n' '# Written by seedtunnel: Transmission may use the data folder of the seedbox' \
        '# (the profile of the system only allows /var/lib/transmission-daemon/downloads).' \
        "\"$dir/\" r," "\"$dir/**\" rwk,"
}

# The profile loaded again with its additions; it applies to Transmission
# right away, even running. A failure is said, never fatal: the diagnostics
# point out what Transmission is refused.
transmission_apparmor_reload() {
    local data_dir=$1
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
            "$APP_LOG" "$data_dir"
    fi
}

# The hash of the password goes through the environment, never as an argument:
# the arguments of every command can be read by every account (ps)
transmission_desired_settings() {
    local data_dir=$1 rpc_user=$2 rpc_hash=$3
    SEEDTUNNEL_HASH=$rpc_hash jq -n --arg dl "$data_dir/complete" \
        --arg inc "$data_dir/incomplete" --arg watch "$data_dir/watch" --arg user "$rpc_user" \
        --argjson rpcport "$TRANSMISSION_RPC_PORT" --argjson peerport "$TORRENT_PORT" \
        "\$ENV.SEEDTUNNEL_HASH as \$hash | $TRANSMISSION_SETTINGS_FILTER"
}

# true if Transmission reads « umask » written as text (4.0 and later)
transmission_umask_text() {
    if transmission_version_at_least 4.0.0~; then echo true; else echo false; fi
}

# Are the wanted settings already in place?
transmission_settings_uptodate() {
    [[ -s $1 ]] || return 1
    jq -e --argjson text_ok "$(transmission_umask_text)" --slurpfile d <(printf '%s' "$2") "$TRANSMISSION_UMASK_JQ"' . as $c | $d[0] | (.umask | umask_value) == ($c.umask | umask_value) and (del(.umask) | to_entries | all(.value == $c[.key]))' "$1" &>/dev/null
}

# Names of the wanted settings that differ (for the log: never their values)
transmission_settings_differences() {
    jq -r --argjson text_ok "$(transmission_umask_text)" --slurpfile d <(printf '%s' "$2") "$TRANSMISSION_UMASK_JQ"' . as $c | $d[0] | (if (.umask | umask_value) != ($c.umask | umask_value) then "umask" else empty end), (del(.umask) | to_entries[] | select(.value != $c[.key]) | .key)' "$1" 2>/dev/null \
        | paste -sd' ' - || true
}

# systemd hardening: if Transmission were compromised, it could only write to
# its own folders and to the download folder.
#
# Nothing can be run from the folders where it, or the SFTP account, can
# write: a program sent by SFTP, then set to run at the end of the downloads
# through the web interface, would run outside the folder SFTP is locked in.
#
# Its settings hold the hash of the password: Transmission writes them again
# when it starts and when it stops (4.1 and later: readable by every account,
# its umask is made for the downloads). They are made private again right
# after, by its own account (never by root, which a link put there could lead
# to another file).
# transmission_generate_dropin DATA [SETTINGS] — SETTINGS: the real file of its
# settings (transmission_settings_file).
transmission_generate_dropin() {
    local home=yes data_dir=$1 settings=${2:-$TRANSMISSION_ETC_SETTINGS}
    case $data_dir in
        /home/* | /root/* | /run/user/*) home=no ;;
    esac
    cat <<EOF
# Written by seedtunnel — Transmission locked down by systemd
[Unit]
# downloads on a disk of their own: never on the system disk if it is missing
RequiresMountsFor=$data_dir

[Service]
# not started on an almost full disk (« + »: this check runs as root)
ExecStartPre=+$APP_DIR/seedtunnel.sh diskguard-prestart
ExecStartPost=-/bin/chmod 600 $settings
ExecStopPost=-/bin/chmod 600 $settings
UMask=0002
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=-/var/lib/transmission-daemon -/etc/transmission-daemon -$data_dir
NoExecPaths=-/var/lib/transmission-daemon -/etc/transmission-daemon -$data_dir
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

# The mounts seen by Transmission running right now (status 1: not running)
transmission_mountinfo() {
    local pid
    pid=$(systemctl show -p MainPID --value transmission-daemon 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    cat "/proc/$pid/mountinfo" 2>/dev/null
}

# transmission_runs_from_data DATA — Transmission is running and could run a
# program put in the folder of the data (the « NoExecPaths » of its drop-in
# not in force: started before it, or set otherwise by another drop-in)
transmission_runs_from_data() {
    local data_dir=$1
    local mounts data
    mounts=$(transmission_mountinfo) || return 1
    [[ -n $mounts ]] || return 1
    # the mounts are named by the real path (no link in it)
    data=$(readlink -f -- "$data_dir" 2>/dev/null) || data=$data_dir
    ! mount_noexec "$data" <<<"$mounts"
}

# transmission_version_at_least VERSION — is the Transmission installed this
# version or a later one? (No: not installed.)
transmission_version_at_least() {
    local version
    version=$(dpkg-query -W -f='${Version}' transmission-daemon 2>/dev/null || true)
    [[ -n $version ]] && dpkg --compare-versions "$version" ge "$1"
}

# Does the Transmission installed know « preferred_transports »? Since
# 4.1.0-beta.4 (in its code: libtransmission/session.h). An older one would
# drop it from its settings, and it would be added again at every run.
transmission_knows_transports() { transmission_version_at_least 4.1.0~beta4; }

# Does the Transmission installed take magnet links (NAME.magnet) from its
# watch folder? Since 4.0.0 (« add magnet file support to watchdir »).
transmission_reads_magnets() { transmission_version_at_least 4.0.0~; }

# Does the Transmission installed also run a program when a torrent is added,
# and when it is done seeding? Since 4.0.0 (« script-torrent-added-* »,
# « script-torrent-done-seeding-* »). Transmission 3 would drop them from its
# settings, and they would be added again at every run.
transmission_knows_more_scripts() { transmission_version_at_least 4.0.0~; }

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

# mount_noexec DIR <MOUNTINFO — is DIR on a mount that runs nothing
# (« noexec »)? The mount that holds it is the one with the longest mount
# point above it, the last one when several are on top of each other.
mount_noexec() {
    awk -v dir="$1" '
        {
            point = $5
            gsub(/\\040/, " ", point)
            above = (point == "/") ? "/" : point "/"
            if (index(dir "/", above) == 1 && length(point) >= best) { best = length(point); options = $6 }
        }
        END { exit !(options ~ /(^|,)noexec(,|$)/) }'
}

transmission_apply_apparmor() {
    local data_dir=$1
    transmission_apparmor_confined || return 0
    install -d -m 755 "${TRANSMISSION_APPARMOR_LOCAL%/*}"
    if write_if_changed "$TRANSMISSION_APPARMOR_LOCAL" 644 root:root transmission_apparmor_generate "$data_dir"; then
        transmission_apparmor_reload "$data_dir"
    fi
}

# On removal: our rules only (a file of the administrator stays)
transmission_remove_apparmor() {
    local data_dir=$1
    grep -q '^# Written by seedtunnel' "$TRANSMISSION_APPARMOR_LOCAL" 2>/dev/null || return 0
    rm -f "$TRANSMISSION_APPARMOR_LOCAL"
    if transmission_apparmor_confined; then transmission_apparmor_reload "$data_dir"; fi
}

transmission_configure() {
    local data_dir=$1 rpc_user=$2 rpc_hash=$3 blocked_query=$4 restore_source=$5 restore_callback=$6
    local settings desired changes restart=0 stopped=0 tmp
    # its message is said: stop there, as die does (not « return »: the
    # error trap would add an « Unexpected error »)
    settings=$(transmission_settings_file) || exit 1
    # a restore: its settings and torrents first, Transmission stopped
    if [[ -n $restore_source ]]; then
        transmission_stop_for_restore
        stopped=1
        "$restore_callback" "$restore_source"
        restart=1
    fi
    desired=$(transmission_desired_settings "$data_dir" "$rpc_user" "$rpc_hash")
    # Transmission 4.1 and later (Ubuntu 26.04): « preferred_transports » wins
    # over « utp-enabled », and without it uTP is on: TCP only there too, even
    # when the file does not have it yet (settings of an older Transmission,
    # brought back by a restore)
    if jq -e 'has("preferred_transports")' "$settings" &>/dev/null || transmission_knows_transports; then
        desired=$(jq -c '. + {"preferred_transports": ["tcp"]}' <<<"$desired")
    fi
    if jq -e 'has("script-torrent-added-enabled")' "$settings" &>/dev/null || transmission_knows_more_scripts; then
        desired=$(jq -c '. + {"script-torrent-added-enabled": false, "script-torrent-added-filename": "", "script-torrent-done-seeding-enabled": false, "script-torrent-done-seeding-filename": ""}' <<<"$desired")
    fi
    install -d -m 755 "${TRANSMISSION_DROPIN%/*}"
    if write_if_changed "$TRANSMISSION_DROPIN" 644 root:root transmission_generate_dropin "$data_dir" "$settings"; then
        run 'Reloading systemd' systemctl daemon-reload
        restart=1
    elif transmission_runs_from_data "$data_dir"; then
        # the file is right, but the Transmission running does not have it
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
            transmission_settings_read "$settings" | jq --slurpfile d <(printf '%s' "$desired") '. + $d[0]'
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
    transmission_make_private "$settings"
    systemctl enable --quiet transmission-daemon 2>/dev/null || true
    # stopped on purpose because the disk is almost full: left alone
    if "$blocked_query"; then return 0; fi
    if ((restart)) || ! systemctl is-active --quiet transmission-daemon; then
        run 'Starting Transmission' systemctl restart transmission-daemon
    fi
}

# Package operations accept shared requirements to retain one checked APT batch.
transmission_install() {
    apt_install transmission-daemon "$@"
}

transmission_purge_packages() {
    apt_purge transmission-daemon transmission-common "$@"
}

transmission_package() { printf '%s' transmission-daemon; }
transmission_service_name() { printf '%s' transmission-daemon; }

# Raw service operations: the caller owns logging and the stop/start policy.
transmission_start() { systemctl start transmission-daemon; }
transmission_stop() { systemctl stop transmission-daemon; }
transmission_restart() { systemctl restart transmission-daemon; }
transmission_disable() { systemctl disable --now transmission-daemon; }
transmission_is_active() { systemctl is-active --quiet transmission-daemon; }

# Only the managed override; never the native state or download directories.
transmission_remove_override() {
    rm -f "$TRANSMISSION_DROPIN" || return $?
    rmdir "${TRANSMISSION_DROPIN%/*}" 2>/dev/null || true
}

# The current backend uses a private group with the same name as its user.
transmission_account() { printf '%s' "$TRANSMISSION_USER"; }
transmission_group() { printf '%s' "$TRANSMISSION_USER"; }

# Read-only descriptors and service observation, independent of feature state.
transmission_display_name() { printf '%s' Transmission; }
transmission_web_path() { printf '%s' /transmission/web/; }
transmission_rpc_path() { printf '%s' /transmission/rpc; }
transmission_observe() { service_observe transmission-daemon "$1"; }

# A successful stop command is not enough: no copying or restitution while
# the state is active or unknown. Reusing a stopped engine avoids a second stop.
transmission_stop_for_restore() {
    local state
    state=$(transmission_runtime_state)
    if [[ $state == active ]]; then
        run 'Stopping Transmission' transmission_stop
        state=$(transmission_runtime_state)
    fi
    if [[ $state != not_running ]]; then
        warn 'Engine stop could not be confirmed; recovery state was not changed.'
        return 1
    fi
}
