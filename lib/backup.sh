#!/usr/bin/env bash
# =============================================================================
#  seedtunnel — backup and restore
#
#  Backup: encrypted archive (AES-256, key derived from the passphrase) with
#  /etc/seedtunnel (keys and clients of the VPN, settings and password hashes
#  of the seedbox, firewall), the Let's Encrypt certificates, the SSH keys of
#  SFTP, and the state of Transmission (list of torrents, progress, settings).
#  Downloaded files are not included: copy them with rsync.
#  All backups go to /var/backups/seedtunnel.
#
#  Weekly backup (« seedtunnel backup auto on »): a systemd timer makes an
#  encrypted backup every week and keeps the last 4. Its passphrase is saved on
#  the server (root only): without it, a backup cannot be restored, so it must
#  also be written down somewhere else.
#
#  « seedtunnel backup share » gives a one-time link to download the latest
#  backup onto a computer: if the server disappears, the backup does not
#  disappear with it. « seedtunnel doctor » reminds you when it was not done
#  for a month.
#
#  Restore: on a new server, puts everything back and installs what is
#  needed. VPN clients keep working without any change if the address of the
#  server (ideally a domain name) points to it.
# =============================================================================

BACKUP_DIR="/var/backups/seedtunnel"
BACKUP_KEEP=4
BACKUP_PASSPHRASE_FILE="$APP_STATE_DIR/backup.passphrase"
# date of the last download of a backup (see backup_share)
BACKUP_DOWNLOADED_MARK="$APP_STATE_DIR/backup.downloaded"
# written while a restore replaces the settings, removed at its end: left
# there by a restore cut short (power cut…), it says where the settings from
# before it are (or « none »)
RESTORE_MARKER="$APP_STATE_DIR.restore-unfinished"
BACKUP_SERVICE="/etc/systemd/system/seedtunnel-backup.service"
BACKUP_TIMER="/etc/systemd/system/seedtunnel-backup.timer"
BACKUP_PASSPHRASE=""
BACKUP_TMP_DIR=""
# during a restore, once the settings in place are replaced: where they went
# (« none » if there were none)
RESTORE_PREVIOUS=""

backup_cleanup() {
    if [[ -n $BACKUP_TMP_DIR && -d $BACKUP_TMP_DIR ]]; then rm -rf "$BACKUP_TMP_DIR"; fi
    BACKUP_TMP_DIR=""
    BACKUP_PASSPHRASE=""
}

# A restore cut short: its marker is still there
restore_interrupted() { [[ -e $RESTORE_MARKER ]]; }

# Settings from before the restore cut short (empty if there were none)
restore_interrupted_previous() {
    local previous=""
    read -r previous 2>/dev/null <"$RESTORE_MARKER" || true
    if [[ $previous != none ]]; then printf '%s' "$previous"; fi
}

# Value of one setting in a settings file of the backup, read in a subshell:
# the settings of this server stay as they are. The file was checked before
# (backup_unsafe_state_file): reading it runs nothing.
restore_backup_setting() {
    (
        state_read "$1"
        printf '%s' "${!2-}"
    )
}

# What the backup brings must fit this server, checked before anything is
# replaced. What lives outside the settings (a running VPN or seedbox, a
# system account, its SSH rule) is not in a backup: a mismatch would leave
# it running without seedtunnel knowing it, or take over an account.
restore_check_server() {
    local settings="$1/etc/seedtunnel" user
    if vpn_installed && [[ ! -f $settings/vpn.conf ]]; then
        die 'This server has a VPN, the backup has none: it would keep running without seedtunnel knowing it. Remove it first (seedtunnel vpn uninstall), or restore on a new server.'
    fi
    if seedbox_installed && [[ ! -f $settings/seedbox.conf ]]; then
        die 'This server has a seedbox, the backup has none: it would keep running without seedtunnel knowing it. Remove it first (seedtunnel seedbox uninstall, the downloads are kept), or restore on a new server.'
    fi
    [[ -f $settings/seedbox.conf ]] || return 0
    user=$(restore_backup_setting "$settings/seedbox.conf" SEEDBOX_USER)
    if seedbox_installed; then
        # the SSH rule follows the account of the backup: the other one would
        # stay, with its password, without its SFTP restrictions
        if [[ $user != "$SEEDBOX_USER" ]]; then
            die 'The seedbox of this server uses the account %s, the backup the account %s: %s would stay without its SFTP restrictions. Rename it first (seedtunnel seedbox password --user %s), or remove the seedbox first.' \
                "$SEEDBOX_USER" "$user" "$SEEDBOX_USER" "$user"
        fi
    else
        # as for an installation: an account of the system is never taken over
        if id -u "$user" &>/dev/null; then
            die 'The account %s of the backup already exists on this server: restoring would change its password and shut it in SFTP. Restore on a server without this account.' "$user"
        fi
        seedbox_check_web_ports
    fi
}

# A restore that stops halfway (error, Ctrl+C) says how to get back to where
# it started: the server may be partly restored. Its marker stays, so that
# « doctor » and the menu say it too, until the way back removes it.
restore_unfinished() {
    case $RESTORE_PREVIOUS in
        "") return 0 ;;
        none)
            warn 'The restore did not finish (details in %s). Once the cause is fixed, run it again.' "$APP_LOG"
            ;;
        *)
            warn 'The restore did not finish (details in %s). Your previous settings are kept in %s. To go back to them:' "$APP_LOG" "$RESTORE_PREVIOUS"
            printf '  rm -rf %s && mv %s %s && rm -f %s && seedtunnel apply\n' \
                "$APP_STATE_DIR" "$RESTORE_PREVIOUS" "$APP_STATE_DIR" "$RESTORE_MARKER" >&2
            ;;
    esac
}

# What goes into the archive (paths without the leading /)
backup_paths() {
    local path settings
    for path in etc/seedtunnel etc/letsencrypt etc/ssh/seedtunnel_authorized_keys \
        "${TRANSMISSION_STATE_DIR#/}/torrents" "${TRANSMISSION_STATE_DIR#/}/resume"; do
        if [[ -e /$path ]]; then printf '%s\n' "$path"; fi
    done
    settings=$(transmission_settings_file)
    if seedbox_installed && [[ -f $settings ]]; then printf '%s\n' "${settings#/}"; fi
}

# Only what seedtunnel saves can be restored
BACKUP_ALLOWED='^(etc/seedtunnel|etc/letsencrypt|etc/ssh/seedtunnel_authorized_keys|var/lib/transmission-daemon/\.config/transmission-daemon/(torrents|resume|settings\.json)|etc/transmission-daemon/settings\.json)(/|$)'

backup_require_something() {
    if ! vpn_installed && ! seedbox_installed && ! firewall_enabled; then
        die 'Nothing to back up: neither VPN, nor seedbox, nor firewall installed.'
    fi
}

# backup_read_passphrase 1|0 — 1: new passphrase (typed twice, 12 characters
# at least). Read from --passphrase-file, from the terminal, or (backups only)
# from the passphrase saved for the weekly backups. In a terminal, a wrong
# entry is asked again, and an empty one goes back: status 1.
backup_read_passphrase() {
    local again
    if [[ -n $OPT_PASSPHRASE_FILE ]]; then
        [[ -r $OPT_PASSPHRASE_FILE ]] || die 'Passphrase file not found: %s' "$OPT_PASSPHRASE_FILE"
        secret_file_check "$OPT_PASSPHRASE_FILE"
        IFS= read -r BACKUP_PASSPHRASE <"$OPT_PASSPHRASE_FILE" || true
    elif stdin_is_terminal; then
        while true; do
            IFS= read -r -s -p "$(t 'Passphrase of the backup (empty = back):') " BACKUP_PASSPHRASE || exit 130
            echo
            [[ -n $BACKUP_PASSPHRASE ]] || return 1
            if ! (($1)); then break; fi
            if ((${#BACKUP_PASSPHRASE} < 12)); then
                warn 'Passphrase: at least 12 characters.'
                continue
            fi
            IFS= read -r -s -p "$(t 'Type it again:') " again || exit 130
            echo
            if [[ $BACKUP_PASSPHRASE == "$again" ]]; then break; fi
            warn 'The two entries differ, try again.'
        done
    elif (($1)) && [[ -r $BACKUP_PASSPHRASE_FILE ]]; then
        IFS= read -r BACKUP_PASSPHRASE <"$BACKUP_PASSPHRASE_FILE" || true
    else
        die 'Without a terminal, give the passphrase with --passphrase-file FILE.'
    fi
    if (($1)) && ((${#BACKUP_PASSPHRASE} < 12)); then die 'Passphrase: at least 12 characters.'; fi
    [[ -n $BACKUP_PASSPHRASE ]] || die 'Empty passphrase.'
}

# Compressed tar archive, then encrypted; the passphrase goes through a file
# descriptor, never as an argument (invisible in « ps »). The archive is
# written to a new temporary file next to its final name (mktemp: unique name,
# never an existing file or link), checked by decrypting it, and only renamed
# once complete: a backup that fails never becomes « the latest backup ».
backup_create_archive() {
    local out=$1 folder partial marker attempt changed
    shift
    folder=$(dirname -- "$out")
    # A setting changed while the archive was written (a restore, certbot,
    # an apply…): it is made again, 3 times at most. An archive mixing two
    # states of the settings is never kept.
    for attempt in 1 2 3; do
        marker=$(mktemp "$folder/.seedtunnel-mark.XXXXXX") || return 1
        # dated one second back: file times move by steps of a few
        # milliseconds, a change in the same step would not look newer
        touch -d '1 second ago' "$marker"
        partial=$(mktemp "$folder/.seedtunnel-backup.XXXXXX") || {
            rm -f "$marker"
            return 1
        }
        if ! tar -czf - --numeric-owner -C / "$@" \
            | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass fd:3 -out "$partial" 3<<<"$BACKUP_PASSPHRASE" \
            || ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass fd:3 -in "$partial" 3<<<"$BACKUP_PASSPHRASE" \
            | tar -tzf - >/dev/null; then
            rm -f "$partial" "$marker"
            return 1
        fi
        if ! changed=$(backup_settings_changed_since "$marker" "$@"); then
            rm -f "$partial" "$marker"
            return 1
        fi
        rm -f "$marker"
        if [[ -z $changed ]]; then
            # « ln » refuses an existing name: an older backup is never replaced
            if ln -- "$partial" "$out"; then
                rm -f "$partial"
                return 0
            fi
            rm -f "$partial"
            return 1
        fi
        printf 'backup, attempt %s: %s changed meanwhile, made again\n' "$attempt" "$changed" >>"$APP_LOG"
        rm -f "$partial"
        # time for the change to end
        sleep 2
    done
    echo "backup: the settings kept changing, no archive kept" >>"$APP_LOG"
    return 1
}

# backup_settings_changed_since MARKER PATH… — the first file or folder of the
# settings saved (not the state of Transmission, which changes all the time)
# changed after MARKER was created. The change time (ctime) is used: « cp -a »
# keeps the modification time, not that one. A file deleted or renamed changes
# the folder it was in. Status 1: they could not be looked at.
backup_settings_changed_since() {
    local marker=$1 path
    local -a settings=()
    shift
    for path in "$@"; do
        if [[ $path != *transmission-daemon* ]]; then settings+=("/$path"); fi
    done
    ((${#settings[@]})) || return 0
    find "${settings[@]}" -cnewer "$marker" -print -quit 2>>"$APP_LOG"
}

# The folder of a backup must belong to root and be writable by root only:
# nobody else can then prepare a file or a link in it
backup_check_folder() {
    local owner="" mode=""
    read -r owner mode < <(stat -L -c '%u %a' -- "$1" 2>/dev/null) || true
    [[ -n $owner ]] || die 'Folder not found: %s' "$1"
    if ((owner != EUID || (8#$mode & 8#022))); then
        die 'The folder %s must belong to root and be writable by root only.' "$1"
    fi
}

# backup_write FILE — encrypted archive with BACKUP_PASSPHRASE
backup_write() {
    local out=$1 old_umask
    local -a paths=()
    mapfile -t paths < <(backup_paths)
    install -d -m 700 "$BACKUP_DIR"
    backup_check_folder "$(dirname -- "$out")"
    # left by a backup interrupted the hard way (power cut)
    find "$(dirname -- "$out")" -maxdepth 1 \( -name '.seedtunnel-backup.*' -o -name '.seedtunnel-mark.*' \) \
        -mmin +1440 -delete 2>/dev/null || true
    old_umask=$(umask)
    umask 077
    run 'Creating the encrypted archive' backup_create_archive "$out" "${paths[@]}"
    umask "$old_umask"
    BACKUP_PASSPHRASE=""
}

backup_file_name() {
    printf '%s/seedtunnel-%s-%s%s.tar.gz.enc' "$BACKUP_DIR" "$(hostname -s)" "$(date +%Y%m%d-%H%M%S)" "${1-}"
}

# Most recent backup (manual or weekly)
backup_latest() {
    local file
    file=$(ls -1t "$BACKUP_DIR"/*.tar.gz.enc 2>/dev/null | head -n 1 || true)
    [[ -n $file ]] && printf '%s' "$file"
}

# Age in days of a file (empty if it does not exist)
file_age_days() {
    local modified
    [[ -e $1 ]] || return 0
    modified=$(stat -c %Y "$1")
    printf '%s' "$((($(date +%s) - modified) / 86400))"
}

backup_main() {
    local out
    banner
    section 'Create an encrypted backup now'
    backup_require_something
    out=${OPT_OUTPUT_FILE:-$(backup_file_name)}
    # an older backup is never replaced
    if [[ -e $out || -L $out ]]; then
        die '%s already exists: choose another name, or delete it first.' "$out"
    fi
    text backup_contents
    echo
    backup_read_passphrase 1 || return 0
    backup_write "$out"
    echo
    ok 'Backup: %s' "$out"
    text backup_after
    pause
}

backup_list() {
    local file
    local -a files=()
    mapfile -t files < <(ls -1t "$BACKUP_DIR"/*.tar.gz.enc 2>/dev/null || true)
    if ((${#files[@]} == 0)); then
        say 'No backup yet in %s.' "$BACKUP_DIR"
        return 0
    fi
    for file in "${files[@]}"; do
        printf '  %s  %s  %s\n' "$(date -r "$file" '+%F %R')" "$(human_size "$(stat -c %s "$file")")" "$file"
    done
}

# One-time link to the latest backup; the download is recorded for the
# reminder of « seedtunnel doctor »
backup_share() {
    local file size
    file=$(backup_latest) || die 'No backup yet:  seedtunnel backup'
    # shown on the download page, to check that the file arrived whole
    size=$(human_size "$(stat -c %s "$file")")
    share_require "$(t 'Without a seedbox, copy it with WinSCP or scp: %s' "$file")"
    banner
    section 'Download the latest backup (one-time link)'
    say 'Backup of %s.' "$(date -r "$file" '+%F %R')"
    share_create "$file" "${file##*/}" "$(t 'seedtunnel backup')" "$(text share_steps_backup)" \
        "$(t 'The backup is encrypted: it cannot be read without its passphrase.')" "$BACKUP_DOWNLOADED_MARK"
}

# --- Weekly backup ---------------------------------------------------------------------

backup_auto_enabled() { systemctl is-enabled --quiet seedtunnel-backup.timer 2>/dev/null; }

backup_generate_service() {
    cat <<EOF
# Written by seedtunnel — encrypted backup, the last $BACKUP_KEEP are kept
[Unit]
Description=seedtunnel: weekly encrypted backup

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=$APP_DIR/seedtunnel.sh backup auto run
EOF
}

backup_generate_timer() {
    cat <<'EOF'
# Written by seedtunnel
[Unit]
Description=seedtunnel: weekly encrypted backup

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Units of the weekly backup (also called after an update or a restore)
backup_auto_install_units() {
    local changed=0
    if write_if_changed "$BACKUP_SERVICE" 644 root:root backup_generate_service; then changed=1; fi
    if write_if_changed "$BACKUP_TIMER" 644 root:root backup_generate_timer; then changed=1; fi
    if ((changed)); then run 'Reloading systemd' systemctl daemon-reload; fi
    unit_ensure_on 'Enabling the weekly backup' seedtunnel-backup.timer
}

backup_auto_enable() {
    banner
    section 'Weekly backup'
    backup_require_something
    text backup_auto_help
    echo
    if [[ -n $(backup_latest) ]]; then
        warn 'The backups already made keep the passphrase they were made with: the new one only applies to the next ones.'
        echo
    fi
    backup_read_passphrase 1 || return 1
    # written next to it, then renamed: if writing fails, the passphrase saved
    # before stays whole
    if ! (umask 077 && printf '%s\n' "$BACKUP_PASSPHRASE" >"$BACKUP_PASSPHRASE_FILE.tmp") \
        || ! mv -f "$BACKUP_PASSPHRASE_FILE.tmp" "$BACKUP_PASSPHRASE_FILE"; then
        rm -f "$BACKUP_PASSPHRASE_FILE.tmp"
        BACKUP_PASSPHRASE=""
        die 'Cannot save the passphrase (disk full? details in %s): the weekly backup was not changed.' "$APP_LOG"
    fi
    BACKUP_PASSPHRASE=""
    backup_auto_install_units
    ok 'Weekly backup on: the last %s are kept in %s.' "$BACKUP_KEEP" "$BACKUP_DIR"
    warn 'Write the passphrase down somewhere else: without it, no backup can be restored.'
}

backup_auto_disable() {
    log_run 'Turning the weekly backup off' systemctl disable --now seedtunnel-backup.timer
    rm -f "$BACKUP_SERVICE" "$BACKUP_TIMER" "$BACKUP_PASSPHRASE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    ok 'Weekly backup off (the existing backups are kept in %s).' "$BACKUP_DIR"
}

# After removing the VPN or the seedbox: with nothing left to back up, the
# weekly backup is turned off
backup_auto_stop_if_unused() {
    if ! vpn_installed && ! seedbox_installed && backup_auto_enabled; then backup_auto_disable; fi
}

# Run by the timer: new backup, then only the last BACKUP_KEEP are kept
backup_auto_run() {
    local file
    [[ -r $BACKUP_PASSPHRASE_FILE ]] || die 'No saved passphrase:  seedtunnel backup auto on'
    backup_require_something
    IFS= read -r BACKUP_PASSPHRASE <"$BACKUP_PASSPHRASE_FILE" || true
    [[ -n $BACKUP_PASSPHRASE ]] || die 'Empty passphrase.'
    file=$(backup_file_name -auto)
    backup_write "$file"
    ls -1t "$BACKUP_DIR"/*-auto.tar.gz.enc 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while IFS= read -r file; do
        rm -f -- "$file"
    done
    ok 'Automatic backup done.'
}

backup_auto_status() {
    local latest age
    if backup_auto_enabled; then
        say 'Weekly backup: on (the last %s are kept in %s)' "$BACKUP_KEEP" "$BACKUP_DIR"
        latest=$(ls -1t "$BACKUP_DIR"/*-auto.tar.gz.enc 2>/dev/null | head -n 1 || true)
        if [[ -n $latest ]]; then say '  Last one: %s' "$(date -r "$latest" '+%F %R')"; fi
    else
        say 'Weekly backup: off   (seedtunnel backup auto on)'
    fi
    age=$(file_age_days "$BACKUP_DOWNLOADED_MARK")
    if [[ -n $age ]]; then
        say 'Last download of a backup started: %s' "$(days_ago "$age")"
    else
        say 'No backup downloaded yet   (seedtunnel backup share)'
    fi
}

# seedtunnel backup …
backup_cli() {
    case ${1-} in
        "") backup_main ;;
        list) backup_list ;;
        share) backup_share ;;
        auto)
            case ${2-} in
                # status 1: empty passphrase, back without doing anything
                on) backup_auto_enable || true ;;
                off) backup_auto_disable ;;
                run) backup_auto_run ;;
                "" | status) backup_auto_status ;;
                *) die 'Usage: seedtunnel backup auto on|off|status' ;;
            esac
            ;;
        *) die 'Usage: seedtunnel backup [list|share|auto on|off|status]' ;;
    esac
}

# Path of a backup to restore, asked again while it cannot be read. Status 1:
# back.
backup_ask_file() {
    local _file_var=$1 _file
    while true; do
        ask_back _file 'Path of the backup file' "$(backup_latest || true)" || return 1
        if [[ -r $_file ]]; then break; fi
        warn 'File not found: %s' "$_file"
    done
    printf -v "$_file_var" '%s' "$_file"
}

backup_menu_share() {
    backup_share
    pause
}

backup_menu_weekly() {
    if backup_auto_enabled; then
        backup_auto_disable
        pause
    elif backup_auto_enable; then
        pause
    fi
}

backup_menu_restore() {
    local file
    banner
    section 'Restore a backup'
    backup_list
    echo
    if backup_ask_file file && restore_main "$file"; then pause; fi
}

backup_menu() {
    local choice
    while true; do
        UI_PLACE=("$(t 'Backup / restore')")
        ui_top "${UI_PLACE[@]}"
        backup_auto_status
        echo
        ui_menu_add 1 "$(t 'Create an encrypted backup now')"
        ui_menu_add 2 "$(t 'Download the latest backup (one-time link)')"
        ui_menu_add 3 "$(t 'Turn the weekly backup on / off')"
        ui_menu_add 4 "$(t 'Restore a backup')"
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action backup_main ;;
            2) ui_action backup_menu_share ;;
            3) ui_action backup_menu_weekly ;;
            4) ui_action backup_menu_restore ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# --- Restore ---------------------------------------------------------------------------

# Puts back the torrents, their progress and the settings of Transmission
restore_transmission_state() {
    local extracted=$1 source="$1$TRANSMISSION_STATE_DIR" settings folder count target
    [[ -d $source/torrents || -d $source/resume ]] || return 0
    run 'Stopping Transmission' systemctl stop transmission-daemon
    install -d -m 755 -o "$TRANSMISSION_USER" -g "$TRANSMISSION_USER" "$TRANSMISSION_STATE_DIR"
    for folder in torrents resume; do
        if [[ -d $source/$folder ]]; then
            rm -rf "${TRANSMISSION_STATE_DIR:?}/$folder"
            cp -a "$source/$folder" "$TRANSMISSION_STATE_DIR/"
            chown -R "$TRANSMISSION_USER:$TRANSMISSION_USER" "$TRANSMISSION_STATE_DIR/$folder"
        fi
    done
    for settings in "$extracted/etc/transmission-daemon/settings.json" "$source/settings.json"; do
        if [[ -f $settings && ! -L $settings ]]; then
            # replaced by renaming, never half-written (the link of Debian
            # points to the real file, and still does)
            target=$(transmission_settings_file)
            install -m 600 -o "$TRANSMISSION_USER" -g "$TRANSMISSION_USER" "$settings" "$target.tmp"
            mv -f "$target.tmp" "$target"
            break
        fi
    done
    # our settings imposed again, then Transmission started
    seedbox_apply_transmission
    count=$(find "$TRANSMISSION_STATE_DIR/torrents" -name '*.torrent' 2>/dev/null | wc -l)
    ok 'List of torrents restored (%s torrent(s)).' "$count"
}

# First entry of the archive that is neither a file nor a folder (link, device,
# hard link…), apart from the links of Let's Encrypt to its own certificates
# (live/NAME/cert.pem → ../../archive/NAME/cert1.pem). Nothing: all fine.
backup_unsafe_entry() {
    local entries
    entries=$(tar -tvzf "$1" 2>>"$APP_LOG") || return 1
    awk '
        { type = substr($1, 1, 1); name = $6 }
        type == "-" || type == "d" { next }
        type == "l" && NF == 8 && $7 == "->" &&
            name ~ /^etc\/letsencrypt\/live\/[^\/]+\/[^\/]+$/ &&
            $8 ~ /^\.\.\/\.\.\/archive\/[^\/]+\/[^\/]+$/ &&
            substr($8, 15) !~ /(^|\/)\.\.?(\/|$)/ { next }
        { print name; exit }' <<<"$entries"
}

# First settings file (read by « . ») under the folder $1 that could run
# something. Nothing: all fine.
backup_unsafe_state_file() {
    local file
    # only the files read by « . »: vpn.conf, seedbox.conf, seedbox.secrets,
    # firewall.conf, vpn/clients/*.env (vpn/clients/*.conf are WireGuard files,
    # never read by bash)
    for file in "$1"/*.conf "$1"/*.secrets "$1"/vpn/clients/*.env; do
        [[ -e $file || -L $file ]] || continue
        if [[ ! -f $file ]] || ! state_file_is_safe "$file"; then
            printf '%s' "$file"
            return 0
        fi
    done
}

restore_main() {
    local file=${1-} list bad stamp was=$INTERACTIVE kept_passphrase=0 kept_firewall=0
    [[ -n $file ]] || die 'Usage: seedtunnel restore FILE'
    [[ -r $file ]] || die 'File not found: %s' "$file"
    banner
    section 'Restore a backup'
    backup_read_passphrase 0 || return 1
    BACKUP_TMP_DIR=$(mktemp -d)
    # the decrypted archive holds secrets: deleted whatever happens (an error
    # that stops the script, Ctrl+C)
    trap 'restore_unfinished; backup_cleanup' EXIT
    trap 'exit 130' INT TERM
    while ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$file" -out "$BACKUP_TMP_DIR/backup.tar.gz" \
        -pass fd:3 3<<<"$BACKUP_PASSPHRASE" 2>>"$APP_LOG"; do
        if [[ -n $OPT_PASSPHRASE_FILE ]] || ! stdin_is_terminal; then
            backup_cleanup
            die 'Cannot decrypt: wrong passphrase or damaged file.'
        fi
        # typed in a terminal: asked again, or back
        warn 'Cannot decrypt: wrong passphrase or damaged file.'
        if ! backup_read_passphrase 0; then
            backup_cleanup
            trap - EXIT INT TERM
            return 1
        fi
    done
    BACKUP_PASSPHRASE=""
    if ! list=$(tar -tzf "$BACKUP_TMP_DIR/backup.tar.gz" 2>>"$APP_LOG"); then
        backup_cleanup
        die 'Unreadable archive.'
    fi
    # Nothing else than what seedtunnel saves is extracted
    bad=$(grep -vE "$BACKUP_ALLOWED" <<<"$list" || true)
    if [[ -n $bad ]]; then
        backup_cleanup
        die 'Archive refused: unexpected path "%s"' "${bad%%$'\n'*}"
    fi
    # Only files and folders: a link could point anywhere (/etc/shadow…), and
    # root would follow it later
    if ! bad=$(backup_unsafe_entry "$BACKUP_TMP_DIR/backup.tar.gz"); then
        backup_cleanup
        die 'Unreadable archive.'
    fi
    if [[ -n $bad ]]; then
        backup_cleanup
        die 'Archive refused: "%s" is a link or a special file' "$bad"
    fi
    mkdir "$BACKUP_TMP_DIR/x"
    run 'Extracting the archive' tar -xzf "$BACKUP_TMP_DIR/backup.tar.gz" --numeric-owner -C "$BACKUP_TMP_DIR/x"
    # The settings are read by « . »: nothing in them may run a command
    bad=$(backup_unsafe_state_file "$BACKUP_TMP_DIR/x/etc/seedtunnel")
    if [[ -n $bad ]]; then
        backup_cleanup
        die 'Archive refused: %s holds something else than settings (it could run commands)' "${bad#"$BACKUP_TMP_DIR/x/"}"
    fi
    restore_check_server "$BACKUP_TMP_DIR/x"
    say 'The backup contains:'
    if grep -qx 'etc/seedtunnel/vpn.conf' <<<"$list"; then say '  - the VPN and its clients'; fi
    if grep -qx 'etc/seedtunnel/seedbox.conf' <<<"$list"; then say '  - the seedbox (settings, passwords, certificates)'; fi
    if grep -q '/transmission-daemon/torrents' <<<"$list"; then say '  - the list of torrents'; fi
    if grep -qx 'etc/seedtunnel/firewall.conf' <<<"$list"; then say '  - the firewall'; fi
    echo
    danger "$(t 'Restore a backup')" "$(t 'The current settings of seedtunnel are replaced by those of the backup (a copy of them is kept in /etc).')"
    if ! confirm 'Restore? The current settings of seedtunnel will be replaced' n; then
        backup_cleanup
        trap - EXIT INT TERM
        return 1
    fi
    echo
    stamp=$(date +%Y%m%d-%H%M%S)
    # the list of the packages installed by seedtunnel describes this server,
    # not the one that was backed up: it stays
    rm -f "$BACKUP_TMP_DIR/x/etc/seedtunnel/packages"
    if [[ -f $APP_STATE_DIR/packages ]]; then cp -p "$APP_STATE_DIR/packages" "$BACKUP_TMP_DIR/x/etc/seedtunnel/"; fi
    # The weekly backup of this server keeps its passphrase when the backup
    # restored was made before it was turned on: its timer is not in the
    # backup and keeps running, and without its passphrase every weekly backup
    # would fail
    if [[ ! -e $BACKUP_TMP_DIR/x/etc/seedtunnel/backup.passphrase && -s $BACKUP_PASSPHRASE_FILE ]] && backup_auto_enabled; then
        cp -p "$BACKUP_PASSPHRASE_FILE" "$BACKUP_TMP_DIR/x/etc/seedtunnel/"
        kept_passphrase=1
    fi
    # The firewall of this server stays on when the backup has none: its
    # rules stay loaded and it is loaded at boot (neither is in a backup);
    # without its settings, seedtunnel would no longer see it nor update it
    if [[ ! -e $BACKUP_TMP_DIR/x/etc/seedtunnel/firewall.conf ]] && firewall_enabled; then
        cp -p "$FIREWALL_CONF_FILE" "$BACKUP_TMP_DIR/x/etc/seedtunnel/"
        if [[ -f $FIREWALL_RULES ]]; then cp -p "$FIREWALL_RULES" "$BACKUP_TMP_DIR/x/etc/seedtunnel/"; fi
        kept_firewall=1
    fi
    # from here on, a restore cut short is said by « doctor » and the menu
    if [[ -n $(find "$APP_STATE_DIR" -mindepth 1 -maxdepth 1 ! -name packages 2>/dev/null || true) ]]; then
        printf '%s\n' "$APP_STATE_DIR.before-restore-$stamp" >"$RESTORE_MARKER"
        mv "$APP_STATE_DIR" "$APP_STATE_DIR.before-restore-$stamp"
        RESTORE_PREVIOUS="$APP_STATE_DIR.before-restore-$stamp"
        warn 'Previous settings moved to %s' "$RESTORE_PREVIOUS"
    else
        printf 'none\n' >"$RESTORE_MARKER"
        rm -rf "$APP_STATE_DIR"
        RESTORE_PREVIOUS=none
    fi
    cp -a "$BACKUP_TMP_DIR/x/etc/seedtunnel" "$APP_STATE_DIR"
    if [[ -d $BACKUP_TMP_DIR/x/etc/letsencrypt ]]; then cp -a "$BACKUP_TMP_DIR/x/etc/letsencrypt" /etc/; fi
    if [[ -d $BACKUP_TMP_DIR/x/etc/ssh/seedtunnel_authorized_keys ]]; then
        cp -a "$BACKUP_TMP_DIR/x/etc/ssh/seedtunnel_authorized_keys" /etc/ssh/
    fi

    # Everything is installed again from the restored settings, without questions
    i18n_init
    vpn_load
    seedbox_load
    INTERACTIVE=0
    if vpn_installed; then
        vpn_check_kernel
        base_setup
        vpn_apply
    fi
    if seedbox_installed; then
        base_setup
        seedbox_apply
        restore_transmission_state "$BACKUP_TMP_DIR/x"
    fi
    if firewall_enabled; then firewall_enable; fi
    if [[ -r $BACKUP_PASSPHRASE_FILE ]]; then
        backup_auto_install_units
    elif backup_auto_enabled; then
        # its timer on, but no passphrase anywhere: it could only fail
        backup_auto_disable
        warn 'Neither the backup restored nor this server has a passphrase for the weekly backup: it was turned off. To turn it on again:  seedtunnel backup auto on'
    fi
    RESTORE_PREVIOUS=""
    rm -f "$RESTORE_MARKER"
    backup_cleanup
    trap - EXIT INT TERM
    INTERACTIVE=$was
    echo
    if ((kept_passphrase)); then
        ok 'The weekly backup of this server is kept, with its passphrase (the backup restored was made before it was turned on).'
    fi
    if ((kept_firewall)); then
        ok 'The firewall of this server stays on (the backup restored has none): its rules were made again for the settings restored.'
    fi
    ok 'Restore finished.'
    if seedbox_installed; then text restore_after; fi
}
