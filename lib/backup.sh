#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
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
# Where a backup copied onto the server is looked for too (WinSCP, scp)
BACKUP_COPIED=('/root/*.tar.gz.enc' '/home/*/*.tar.gz.enc')
# 1 while the backup is made from the menu: its download is offered after it
BACKUP_FROM_MENU=0
BACKUP_KEEP=4
BACKUP_PASSPHRASE_FILE="$APP_STATE_DIR/backup.passphrase"
# System the backup was made on (« ubuntu 24.04 »): a restore on another one is said
BACKUP_SYSTEM_FILE="$APP_STATE_DIR/system"
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
# during a restore: the SFTP account of this server that takes the name of the
# one in the backup (renamed since the backup), and that name
RESTORE_RENAME_FROM=""
RESTORE_RENAME_TO=""
# magnet links of the backup that Transmission 3 cannot take from watch/
RESTORE_MAGNETS_FILE="/root/seedtunnel-magnets.txt"

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
    RESTORE_RENAME_FROM=""
    RESTORE_RENAME_TO=""
    if vpn_installed && [[ ! -f $settings/vpn.conf ]]; then
        die 'This server has a VPN, the backup has none: it would keep running without seedtunnel knowing it. Remove it first (seedtunnel vpn uninstall), or restore on a new server.'
    fi
    if seedbox_installed && [[ ! -f $settings/seedbox.conf ]]; then
        die 'This server has a seedbox, the backup has none: it would keep running without seedtunnel knowing it. Remove it first (seedtunnel seedbox uninstall, the downloads are kept), or restore on a new server.'
    fi
    if [[ ! -f $settings/seedbox.conf ]]; then
        # the site of the links of the backup: nginx on 80 and 443, as for a
        # seedbox
        if [[ -f $settings/links.conf ]] && ! links_site_on; then seedbox_check_web_ports links; fi
        return 0
    fi
    user=$(restore_backup_setting "$settings/seedbox.conf" SEEDBOX_USER)
    if seedbox_installed; then
        # the account renamed since the backup takes back the name of the
        # backup (in restore_main, once the way back knows it): the SSH rule
        # follows that name, and the account must not stay under the other
        # one without its SFTP restrictions. Never an account of the system
        # that is not the one of the seedbox
        if [[ $user != "$SEEDBOX_USER" ]]; then
            if id -u "$user" &>/dev/null; then
                die 'The account %s of the backup already exists on this server: restoring would change its password and shut it in SFTP. Restore on a server without this account.' "$user"
            fi
            # (an account already gone: seedbox_apply makes the one of the backup)
            if id -u "$SEEDBOX_USER" &>/dev/null; then
                RESTORE_RENAME_FROM=$SEEDBOX_USER
                RESTORE_RENAME_TO=$user
            fi
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
            if [[ -f $RESTORE_PREVIOUS.undo ]]; then
                warn 'The restore did not finish (details in %s). What it replaced is kept in %s. To go back to it (settings, SSH keys of SFTP, certificate, list of torrents):' "$APP_LOG" "$RESTORE_PREVIOUS"
                printf '  bash %s.undo\n' "$RESTORE_PREVIOUS" >&2
            else
                warn 'The restore did not finish (details in %s). Your previous settings are kept in %s. To go back to them:' "$APP_LOG" "$RESTORE_PREVIOUS"
                printf '  rm -rf %s && mv %s %s && rm -f %s && seedtunnel apply\n' \
                    "$APP_STATE_DIR" "$RESTORE_PREVIOUS" "$APP_STATE_DIR" "$RESTORE_MARKER" >&2
            fi
            ;;
    esac
}

# restore_keep_outside PREVIOUS — what a restore replaces outside
# /etc/seedtunnel is kept too, beside the previous settings (PREVIOUS.outside):
# the SSH keys of SFTP, the certificate of seedtunnel, the list of torrents.
# PREVIOUS.undo puts everything back, if the restore does not finish.
restore_keep_outside() {
    local previous=$1 outside="$1.outside" part
    install -d -m 700 "$outside"
    if [[ -d $SFTP_KEYS_DIR ]]; then cp -a "$SFTP_KEYS_DIR" "$outside/ssh-keys"; fi
    for part in "live/$LETSENCRYPT_CERT_NAME" "archive/$LETSENCRYPT_CERT_NAME" "renewal/$LETSENCRYPT_CERT_NAME.conf"; do
        if [[ -e $LETSENCRYPT_ROOT/$part ]]; then
            install -d -m 700 "$outside/letsencrypt/${part%/*}"
            cp -a "$LETSENCRYPT_ROOT/$part" "$outside/letsencrypt/${part%/*}/"
        fi
    done
    for part in torrents resume; do
        if [[ -d $TRANSMISSION_STATE_DIR/$part ]]; then
            install -d -m 700 "$outside/transmission"
            cp -a "$TRANSMISSION_STATE_DIR/$part" "$outside/transmission/"
        fi
    done
    (umask 077 && restore_undo_script "$previous" >"$previous.undo")
}

# restore_undo_script PREVIOUS — the script that puts back what was there
# before the restore (see restore_keep_outside)
restore_undo_script() {
    local previous=$1 outside="$1.outside"
    cat <<EOF
#!/bin/bash
# Written by seedtunnel: puts back what was there before a restore that did
# not finish (settings, SSH keys of SFTP, certificate, list of torrents).
set -e
systemctl stop transmission-daemon 2>/dev/null || true
rm -rf -- $(printf '%q' "$APP_STATE_DIR")
mv -T -- $(printf '%q %q' "$previous" "$APP_STATE_DIR")
rm -rf -- $(printf '%q' "$SFTP_KEYS_DIR")
if [ -d $(printf '%q' "$outside/ssh-keys") ]; then cp -a -- $(printf '%q %q' "$outside/ssh-keys" "$SFTP_KEYS_DIR"); fi
for part in $(printf '%q %q %q' "live/$LETSENCRYPT_CERT_NAME" "archive/$LETSENCRYPT_CERT_NAME" "renewal/$LETSENCRYPT_CERT_NAME.conf"); do
    rm -rf -- $(printf '%q' "$LETSENCRYPT_ROOT")/"\$part"
    if [ -e $(printf '%q' "$outside/letsencrypt")/"\$part" ]; then
        mkdir -p $(printf '%q' "$LETSENCRYPT_ROOT")/"\${part%/*}"
        cp -a -- $(printf '%q' "$outside/letsencrypt")/"\$part" $(printf '%q' "$LETSENCRYPT_ROOT")/"\${part%/*}/"
    fi
done
for part in torrents resume; do
    rm -rf -- $(printf '%q' "$TRANSMISSION_STATE_DIR")/"\$part"
    if [ -d $(printf '%q' "$outside/transmission")/"\$part" ]; then cp -a -- $(printf '%q' "$outside/transmission")/"\$part" $(printf '%q' "$TRANSMISSION_STATE_DIR")/; fi
done
$(restore_undo_rename)
rm -f -- $(printf '%q' "$RESTORE_MARKER")
rm -rf -- $(printf '%q' "$outside")
seedtunnel apply
rm -f -- "\$0"
EOF
}

# In the way back: the SFTP account renamed by the restore gets its name back
# (nothing if it was not renamed, or not yet)
restore_undo_rename() {
    [[ -n $RESTORE_RENAME_FROM ]] || return 0
    local from to
    from=$(printf '%q' "$RESTORE_RENAME_FROM")
    to=$(printf '%q' "$RESTORE_RENAME_TO")
    cat <<EOF
if id -u $to >/dev/null 2>&1 && ! id -u $from >/dev/null 2>&1; then
    usermod --login $from $to
    if getent group $to >/dev/null; then groupmod --new-name $from $to; fi
fi
EOF
}

# What goes into the archive (paths without the leading /)
backup_paths() {
    local path settings
    for path in etc/seedtunnel etc/letsencrypt etc/ssh/seedtunnel_authorized_keys \
        "${TRANSMISSION_STATE_DIR#/}/torrents" "${TRANSMISSION_STATE_DIR#/}/resume"; do
        if [[ -e /$path ]]; then printf '%s\n' "$path"; fi
    done
    # its settings, if they are where they should be (said otherwise)
    if seedbox_installed && settings=$(transmission_settings_file) && [[ -f $settings ]]; then
        printf '%s\n' "${settings#/}"
    fi
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

# tar for a backup: a file changed or removed while it was read (Transmission
# writes its progress files while it runs) is no failure, only status 1 of GNU
# tar. Those files are not restored any more (the torrents go back through
# watch/), and a change of the settings meanwhile is caught after the archive.
backup_tar() {
    local status=0
    tar "$@" || status=$?
    ((status <= 1)) || return "$status"
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
        # the fingerprints of the files written, and the copies of those changed
        # by hand, describe this server: not in the backup (restored by an
        # older seedtunnel, they would make the next version see changes)
        if ! backup_tar -czf - --warning=no-file-changed --warning=no-file-removed --numeric-owner \
            --exclude="${APP_STATE_DIR#/}/written.sha256" \
            --exclude="${APP_STATE_DIR#/}/changed-by-hand" --exclude="${APP_STATE_DIR#/}/backup.downloaded" -C / "$@" \
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
        log_print 'backup, attempt %s: %s changed meanwhile, made again\n' "$attempt" "$changed"
        rm -f "$partial"
        # time for the change to end
        sleep 2
    done
    log_print 'backup: the settings kept changing, no archive kept\n'
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

# backup_note_system — the system of this server, written only if it changed
backup_note_system() {
    local system="$APP_OS_ID $APP_OS_VERSION"
    [[ -n $APP_OS_ID ]] || return 0
    [[ $(cat "$BACKUP_SYSTEM_FILE" 2>/dev/null) != "$system" ]] || return 0
    printf '%s\n' "$system" >"$BACKUP_SYSTEM_FILE"
    chmod 600 "$BACKUP_SYSTEM_FILE"
    # the archive is made again when a setting changed less than a second
    # before it starts (backup_create_archive): this change must be older
    sleep 2
}

# backup_write FILE — encrypted archive with BACKUP_PASSPHRASE
backup_write() {
    local out=$1 old_umask bad
    local -a paths=()
    # a backup that could not be restored says it now, not on the day it is
    # needed (the restore refuses the same files)
    bad=$(backup_unsafe_state_file "$APP_STATE_DIR")
    if [[ -n $bad ]]; then
        die 'This backup could not be restored: %s holds something else than settings. Run « seedtunnel doctor ».' "$bad"
    fi
    backup_note_system
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

# Age of a file in calendar days: 0 today, 1 yesterday… (empty if it does not
# exist). Days of the calendar, not slices of 24 hours: a file of yesterday
# 22:00 is « yesterday » at 09:00. Each date is taken at noon UTC, so that a
# change of time (summer, winter) never moves it by a day.
file_age_days() {
    local modified day today
    [[ -e $1 ]] || return 0
    modified=$(stat -c %Y "$1")
    day=$(date -u -d "$(date -d "@$modified" +%F) 12:00" +%s)
    today=$(date -u -d "$(date +%F) 12:00" +%s)
    printf '%s' "$(((today - day) / 86400))"
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
    # from the menu: its download offered right away
    if ((BACKUP_FROM_MENU)); then
        backup_offer_link "$out"
        return 0
    fi
    text backup_after
    pause
}

# backup_offer_link FILE — after a backup made from the menu, the one-time
# link to it, if wanted (otherwise: My backups, later)
backup_offer_link() {
    say 'Without the passphrase, it cannot be recovered.'
    echo
    if confirm 'Download it now (one-time link)?' y; then
        backup_share_file "$1" 'Download a backup (one-time link)'
    fi
    pause
}

# The backups that can be restored, the newest first: those of the server, and
# those copied into the folder of root or of a user (WinSCP, scp). Links are
# left out: another account could put first, under a recent name, a link to
# an old backup of the server.
backup_candidates() {
    local pattern file
    local -a files=()
    for pattern in "$BACKUP_DIR/*.tar.gz.enc" "${BACKUP_COPIED[@]}"; do
        while IFS= read -r file; do
            if [[ -f $file && ! -L $file ]]; then files+=("$file"); fi
        done < <(compgen -G "$pattern" || true)
    done
    ((${#files[@]})) || return 0
    ls -1t -- "${files[@]}" 2>/dev/null || true
}

# backup_line FILE — « 2026-11-10 21:10  12K  /var/backups/seedtunnel/… »
backup_line() {
    printf '%s  %s  %s' "$(date -r "$1" '+%F %R')" "$(human_size "$(stat -c %s "$1")")" "$1"
}

# The backups, numbered as in the menu: « seedtunnel backup share|delete
# NUMBER » take these numbers
backup_list() {
    local file index=0
    while IFS= read -r file; do
        index=$((index + 1))
        printf '  %s  %s\n' "$index" "$(backup_line "$file")"
    done < <(backup_candidates)
    if ((!index)); then say 'No backup found in %s, nor in /root and /home.' "$BACKUP_DIR"; fi
}

# backup_kind FILE — made by hand or weekly by this server, or copied into
# /root or a home folder (WinSCP, scp)
backup_kind() {
    if [[ $1 != "$BACKUP_DIR"/* ]]; then
        t 'copied'
    elif [[ $1 == *-auto.tar.gz.enc ]]; then
        t 'weekly'
    else
        t 'by hand'
    fi
}

# backup_table FILE… — the backups in a table, numbered from 1
backup_table() {
    local file folder index=0
    local -a rows=("#"$'\t'"$(t 'DATE')"$'\t'"$(t 'SIZE')"$'\t'"$(t 'KIND')"$'\t'"$(t 'FOLDER')")
    for file in "$@"; do
        index=$((index + 1))
        # no character that the terminal would take for a command
        folder=${file%/*}
        folder=${folder//[$'\001'-$'\037'$'\177']/?}
        rows+=("$index"$'\t'"$(date -r "$file" '+%F %R')"$'\t'"$(human_size "$(stat -c %s "$file")")"$'\t'"$(backup_kind "$file")"$'\t'"$folder")
    done
    ui_width
    ui_table "${rows[@]}"
}

# backup_by_number VARIABLE NUMBER — the backup of that number in the list
backup_by_number() {
    local -a files
    mapfile -t files < <(backup_candidates)
    if [[ ! $2 =~ ^[0-9]{1,9}$ ]] || ((10#$2 < 1 || 10#$2 > ${#files[@]})); then
        die 'No backup number %s (seedtunnel backup list).' "$2"
    fi
    printf -v "$1" '%s' "${files[10#$2 - 1]}"
}

# backup_ask_number VARIABLE QUESTION FILE… — one of the backups listed, by
# its number, asked again while it is not in the list. Status 1: back.
backup_ask_number() {
    local _bn_var=$1 _bn_question=$2 _bn_answer
    shift 2
    while true; do
        ask_back _bn_answer "$_bn_question" || return 1
        if [[ $_bn_answer =~ ^[0-9]{1,9}$ ]] && ((10#$_bn_answer >= 1 && 10#$_bn_answer <= $#)); then
            _bn_answer=$((10#$_bn_answer))
            printf -v "$_bn_var" '%s' "${!_bn_answer}"
            return 0
        fi
        warn 'No backup number %s.' "$_bn_answer"
    done
}

# backup_share [NUMBER] — one-time link to the latest backup, or to the one of
# that number; the download is recorded for the reminder of « seedtunnel doctor »
backup_share() {
    local file
    if [[ -n ${1-} ]]; then
        backup_by_number file "$1"
        backup_share_file "$file" 'Download a backup (one-time link)'
    else
        file=$(backup_latest) || die 'No backup yet:  seedtunnel backup'
        backup_share_file "$file" 'Download the latest backup (one-time link)'
    fi
}

# backup_share_file FILE TITLE
backup_share_file() {
    local file=$1 size
    # shown on the download page, to check that the file arrived whole
    size=$(human_size "$(stat -c %s "$file")")
    banner
    section "$2"
    share_require "$(t 'Without a link, copy it with WinSCP or scp: %s' "$file")" || return 0
    say 'Backup of %s.' "$(date -r "$file" '+%F %R')"
    share_create "$file" "${file##*/}" "$(t 'seedtunnel backup')" "$(text share_steps_backup)" \
        "$(t 'The backup is encrypted: it cannot be read without its passphrase.')" "$BACKUP_DOWNLOADED_MARK"
}

# backup_listed FILE — FILE is one of the backups of the list (backup_candidates:
# regular files, never a link)
backup_listed() {
    local listed
    while IFS= read -r listed; do
        if [[ $listed == "$1" ]]; then return 0; fi
    done < <(backup_candidates)
    return 1
}

# backup_delete FILE — one backup of the list deleted for good, after a
# question in red (« no » by default). Said in the frame: the last backup of
# this server; a backup copied by hand into /root or a home folder (perhaps
# the only copy of it). A link made before keeps its own copy.
backup_delete() {
    local file=$1 other others=0
    local -a lines
    WENT_BACK=0
    backup_listed "$file" || die 'Not a backup of the list (seedtunnel backup list): %s' "$file"
    for other in "$BACKUP_DIR"/*.tar.gz.enc; do
        if [[ -f $other && $other != "$file" ]]; then others=$((others + 1)); fi
    done
    lines=("$(t 'The backup of %s (%s, %s) is deleted for good.' "$(date -r "$file" '+%F %R')" \
        "$(human_size "$(stat -c %s "$file")")" "$(backup_kind "$file")")")
    if [[ $file != "$BACKUP_DIR"/* ]]; then
        lines+=("$(t 'It was copied by hand into %s (WinSCP, scp): it may be your only copy.' "${file%/*}")")
    elif ((!others)); then
        lines+=("$(t 'It is the only backup on the server: keep a copy of it on your computer first.')")
    fi
    danger "$(t 'Delete a backup')" "${lines[@]}"
    if ! confirm 'Delete this backup?' n; then
        WENT_BACK=1
        return 0
    fi
    run "$(t 'Deleting %s' "${file##*/}")" rm -f -- "$file"
    ok 'Backup deleted: %s' "${file##*/}"
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
    WENT_BACK=0
    banner
    section 'Weekly backup'
    backup_require_something
    ui_width
    ui_field_add "$(t 'When')" "$(t 'every week, by itself (encrypted)')"
    ui_field_add "$(t 'Kept')" "$(t 'the last %s, in %s' "$BACKUP_KEEP" "$C_CYAN$BACKUP_DIR$C_RESET")"
    ui_field_add Passphrase "$(t 'saved on the server (root only), so that it runs alone: write it down somewhere else too')"
    ui_box_fields good "$(t 'Weekly backup')"
    echo
    if [[ -n $(backup_latest) ]]; then
        warn 'The backups already made keep the passphrase they were made with: the new one only applies to the next ones.'
        echo
    fi
    if ! backup_read_passphrase 1; then
        WENT_BACK=1
        return 0
    fi
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

# Turning the weekly backup off from the menu or « backup auto off »: what it
# does is said, then asked (« no » by default; --yes without a terminal). Not
# when the VPN and the seedbox are removed: nothing is left to back up then.
backup_auto_disable_asked() {
    WENT_BACK=0
    banner
    section 'Turn the weekly backup off'
    danger "$(t 'Turn the weekly backup off')" "$(t 'No more encrypted backup every week.')" \
        "$(t 'The passphrase saved on the server is deleted: the backups already made open only with the one you wrote down.')" \
        "$(t 'They stay in %s.' "$BACKUP_DIR")"
    if ! confirm 'Turn the weekly backup off?' n; then
        WENT_BACK=1
        return 0
    fi
    backup_auto_disable
}

backup_auto_disable() {
    log_run 'Turning the weekly backup off' systemctl disable --now seedtunnel-backup.timer
    rm -f "$BACKUP_SERVICE" "$BACKUP_TIMER" "$BACKUP_PASSPHRASE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    ok 'Weekly backup off (the existing backups are kept in %s).' "$BACKUP_DIR"
}

# backup_removal_note vpn|seedbox — said before removing the other one: when
# nothing is left to back up after it, the weekly backup stops and its
# passphrase saved on the server is deleted (backup_auto_stop_if_unused)
backup_removal_note() {
    local still=0
    case $1 in
        vpn) if vpn_installed; then still=1; fi ;;
        seedbox) if seedbox_installed; then still=1; fi ;;
    esac
    if ((still)) || ! backup_auto_enabled; then return 0; fi
    t 'The weekly backup stops too, and its passphrase saved on the server is deleted: the backups already made open only with the one you wrote down.'
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

# The state of the backups in the menu, in aligned fields: the weekly backup
# (green on, yellow off, red failed: the last run failed, or its passphrase is
# missing), the latest backup, how many are on the server, the last download
# (yellow: none yet)
backup_status_fields() {
    local weekly latest age value count=0 file
    if ! backup_auto_enabled; then
        weekly="$C_YELLOW● $(t 'turned off')$C_RESET"
    elif systemctl is-failed --quiet seedtunnel-backup.service 2>/dev/null || [[ ! -s $BACKUP_PASSPHRASE_FILE ]]; then
        weekly="$C_RED● $(t 'failed')$C_RESET"
    else
        weekly="$C_GREEN● $(t 'turned on')$C_RESET · $C_GREY$(t 'the last %s are kept' "$BACKUP_KEEP")$C_RESET"
    fi
    ui_field_add "$(t 'Weekly')" "$weekly"
    latest=$(backup_latest || true)
    if [[ -n $latest ]]; then
        age=$(file_age_days "$latest")
        value="$(date -r "$latest" '+%F %R') $C_GREY($(days_ago "$age"))$C_RESET"
    else
        value="$C_YELLOW● $(t 'none yet')$C_RESET"
    fi
    ui_field_add "$(t 'Latest')" "$value"
    for file in "$BACKUP_DIR"/*.tar.gz.enc; do
        if [[ -f $file ]]; then count=$((count + 1)); fi
    done
    ui_field_add "$(t 'On the server')" "$(t '%s in %s' "$count" "$C_CYAN$BACKUP_DIR$C_RESET")"
    age=$(file_age_days "$BACKUP_DOWNLOADED_MARK")
    if [[ -n $age ]]; then value=$(days_ago "$age"); else value="$C_YELLOW● $(t 'not yet')$C_RESET"; fi
    ui_field_add "$(t 'Downloaded')" "$value"
    ui_fields_show
}

# seedtunnel backup …
backup_cli() {
    local file
    case ${1-} in
        "") backup_main ;;
        list) backup_list ;;
        share) backup_share "${2-}" ;;
        delete)
            [[ -n ${2-} ]] || die 'Usage: seedtunnel backup delete NUMBER (the numbers: seedtunnel backup list)'
            backup_by_number file "$2"
            backup_delete "$file"
            ;;
        auto)
            case ${2-} in
                # empty passphrase or « no »: back without doing anything
                on) backup_auto_enable ;;
                off) backup_auto_disable_asked ;;
                run) backup_auto_run ;;
                "" | status) backup_auto_status ;;
                *) die 'Usage: seedtunnel backup auto on|off|status' ;;
            esac
            ;;
        *) die 'Usage: seedtunnel backup [list|share [NUMBER]|delete NUMBER|auto on|off|status]' ;;
    esac
}

# backup_pick_file VARIABLE — the backups found, in a table, the newest first:
# one is chosen by its number (Enter: the newest), or any file by its path.
# Asked again while the file cannot be read. Status 1: back.
backup_pick_file() {
    local _bp_var=$1 _bp_answer _bp_index _bp_default=""
    local -a _bp_files
    mapfile -t _bp_files < <(backup_candidates)
    _bp_index=${#_bp_files[@]}
    if ((_bp_index)); then backup_table "${_bp_files[@]}"; fi
    # Enter takes the newest one only if it was made by this server
    if [[ ${_bp_files[0]-} == "$BACKUP_DIR"/* ]]; then _bp_default=1; fi
    if ((_bp_index == 0)); then say 'No backup found in %s, nor in /root and /home.' "$BACKUP_DIR"; fi
    echo
    while true; do
        if ((_bp_index)); then
            ask_back _bp_answer 'Backup to restore (number, or path of a file)' "$_bp_default" || return 1
        else
            ask_back _bp_answer 'Path of the backup file' "" || return 1
        fi
        # a path pasted between quotes (« Copy as path » of Windows), or from ~
        if [[ $_bp_answer == \"*\" || $_bp_answer == \'*\' ]]; then _bp_answer=${_bp_answer:1:-1}; fi
        # shellcheck disable=SC2088 # a « ~ » typed, not one to expand
        if [[ $_bp_answer == "~/"* ]]; then _bp_answer=$HOME/${_bp_answer#"~/"}; fi
        if [[ $_bp_answer =~ ^[0-9]{1,9}$ ]]; then
            # « 08 »: a number in base 10 (bash would read an octal number)
            _bp_answer=$((10#$_bp_answer))
            if ((_bp_answer >= 1 && _bp_answer <= _bp_index)); then
                _bp_answer=${_bp_files[_bp_answer - 1]}
                break
            fi
            warn 'No backup number %s.' "$_bp_answer"
            continue
        fi
        if [[ -f $_bp_answer && -r $_bp_answer ]]; then break; fi
        warn 'File not found: %s' "$_bp_answer"
    done
    printf -v "$_bp_var" '%s' "$_bp_answer"
}

# [1] of the menu: the backup, then its download offered
backup_menu_create() {
    BACKUP_FROM_MENU=1
    backup_main
}

# The screen of the backups: the table (those of the server and those copied
# into /root or a home folder), the room they take, then download or delete
backup_menu_mine() {
    local choice file total=0 leftovers
    local -a files
    while true; do
        mapfile -t files < <(backup_candidates)
        UI_PLACE=("$(t 'Backup / restore')" "$(t 'My backups')")
        ui_top "${UI_PLACE[@]}"
        if ((${#files[@]})); then
            backup_table "${files[@]}"
        else
            say 'No backup found in %s, nor in /root and /home.' "$BACKUP_DIR"
        fi
        echo
        total=0
        for file in "$BACKUP_DIR"/*.tar.gz.enc; do
            if [[ -f $file && ! -L $file ]]; then total=$((total + $(stat -c %s "$file"))); fi
        done
        ui_field_add "$(t 'Space used')" "$(human_size_spaced "$total") $C_GREY$(t 'in %s' "$BACKUP_DIR")$C_RESET"
        ui_field_add "$(t 'Disk')" "$(disk_free_text "$BACKUP_DIR")"
        # the settings replaced by a restore, while kept (never during a
        # restore cut short: its way back)
        leftovers=$(restore_leftovers_dates)
        if [[ $leftovers == *", "* ]]; then
            ui_field_add "$(t 'Old settings')" "$C_YELLOW$(t 'kept since the restores of %s' "$leftovers")$C_RESET $C_GREY· $(t 'to delete once everything works')$C_RESET"
        elif [[ -n $leftovers ]]; then
            ui_field_add "$(t 'Old settings')" "$C_YELLOW$(t 'kept since the restore of %s' "$leftovers")$C_RESET $C_GREY· $(t 'to delete once everything works')$C_RESET"
        fi
        ui_fields_show
        echo
        ui_menu_add 1 "$(t 'Download a backup (one-time link)')"
        ui_menu_add 2 "$(t 'Delete a backup')"
        if [[ -n $leftovers ]]; then ui_menu_add 3 "$(t 'Delete the old settings')"; fi
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action backup_menu_mine_share ;;
            2) ui_action backup_menu_mine_delete ;;
            3) if [[ -n $leftovers ]]; then ui_action backup_menu_mine_clean; fi ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

backup_menu_mine_share() {
    local file
    local -a files
    mapfile -t files < <(backup_candidates)
    ((${#files[@]})) || return 0
    backup_ask_number file 'Backup to download (number)' "${files[@]}" || return 0
    backup_share_file "$file" 'Download a backup (one-time link)'
    pause
}

backup_menu_mine_delete() {
    local file
    local -a files
    mapfile -t files < <(backup_candidates)
    ((${#files[@]})) || return 0
    backup_ask_number file 'Backup to delete (number)' "${files[@]}" || return 0
    backup_delete "$file"
    if ((!WENT_BACK)); then pause; fi
}

backup_menu_mine_clean() {
    restore_clean
    if ((!WENT_BACK)); then pause; fi
}

backup_menu_weekly() {
    if backup_auto_enabled; then
        backup_auto_disable_asked
    else
        backup_auto_enable
    fi
    if ((!WENT_BACK)); then pause; fi
}

backup_menu_restore() {
    local file
    banner
    section 'Restore a backup'
    # ufw on: said before the choice of the file, not after
    ufw_refuse
    backup_pick_file file || return 0
    restore_main "$file"
    if ((!WENT_BACK)); then pause; fi
}

backup_menu() {
    local choice
    while true; do
        UI_PLACE=("$(t 'Backup / restore')")
        ui_top "${UI_PLACE[@]}"
        backup_status_fields
        echo
        ui_menu_add 1 "$(t 'Create an encrypted backup now')"
        ui_menu_add 2 "$(t 'Turn the weekly backup on / off')"
        ui_menu_add 3 "$(t 'Restore a backup')"
        ui_menu_add 4 "$(t 'My backups (list, download, delete)')"
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action backup_menu_create ;;
            2) ui_action backup_menu_weekly ;;
            3)
                ui_action backup_menu_restore
                # the menus go on in the language of the backup restored
                language_reload
                ;;
            4) backup_menu_mine ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# --- Restore ---------------------------------------------------------------------------

# restore_transmission_state EXTRACTED — puts back the settings of Transmission
# and its list of torrents, while Transmission is stopped (called by
# seedbox_apply_transmission, see TRANSMISSION_RESTORE_FROM: one restart only).
# The torrents go back through the watch folder, as new ones: Transmission
# checks each one against the files already there before starting it —
# complete if they were copied back, from zero otherwise. Their progress files
# are not put back: Transmission 3 (Debian 12) does not read those of
# Transmission 4, and a torrent that believes it has its files, on a new server
# without them, stays in error until it is checked by hand.
restore_transmission_state() {
    local extracted=$1 source="$1$TRANSMISSION_STATE_DIR" settings target torrent count=0 magnets=0 link
    local -a by_hand=()
    local watch="$SEEDBOX_DATA_DIR/watch"
    for settings in "$extracted/etc/transmission-daemon/settings.json" "$source/settings.json"; do
        if [[ -f $settings && ! -L $settings ]]; then
            # written by the account of Transmission, replaced by renaming
            # (the link of Debian points to the real file, and still does)
            target=$(transmission_settings_file) || exit 1
            transmission_settings_write "$target" "$settings"
            break
        fi
    done
    # a backup without the state of Transmission: the list of the server stays
    [[ -d $source/torrents || -d $source/resume ]] || return 0
    log_title 'Putting the torrents of the backup back through %s' "$watch/"
    # the list of the server is replaced by the one of the backup (the files
    # downloaded stay where they are)
    rm -rf "${TRANSMISSION_STATE_DIR:?}/torrents" "${TRANSMISSION_STATE_DIR:?}/resume"
    install -d -m 755 -o "$TRANSMISSION_USER" -g "$TRANSMISSION_USER" "$TRANSMISSION_STATE_DIR"
    # Written by Transmission's own account, never by root: the SFTP user also
    # writes in watch/, and could put a link there to make root write elsewhere.
    # Written aside, then renamed: a link put under the same name is replaced,
    # never followed (it would lead to a file of Transmission), and Transmission
    # never sees a torrent half-written (it only takes the names in .torrent).
    # Readable by Transmission (a .torrent of root left unreadable is never added).
    for torrent in "$source/torrents"/*.torrent; do
        [[ -f $torrent && ! -L $torrent ]] || continue
        if restore_watch_write "$watch/${torrent##*/}" <"$torrent"; then
            count=$((count + 1))
        else
            warn 'Torrent not put back (details in %s): %s' "$APP_LOG" "${torrent##*/}"
        fi
    done
    # Added by a magnet link, without their metadata yet: Transmission 4 keeps
    # only their link, in HASH.magnet. Transmission 4 reads them in watch/ too; Transmission 3 (Debian
    # 12) does not: they are saved in a file, to add them again by hand.
    for torrent in "$source/torrents"/*.magnet; do
        [[ -f $torrent && ! -L $torrent ]] || continue
        if ! link=$(magnet_link_read "$torrent"); then
            warn 'Magnet link not put back (unexpected content): %s' "${torrent##*/}"
        elif ! transmission_reads_magnets; then
            by_hand+=("$link")
        elif printf '%s' "$link" | restore_watch_write "$watch/${torrent##*/}"; then
            magnets=$((magnets + 1))
        else
            warn 'Magnet link not put back (details in %s): %s' "$APP_LOG" "${torrent##*/}"
        fi
    done
    log_print '%s torrent(s) put in %s\n' "$count" "$watch/"
    if ((magnets)); then log_print '%s magnet link(s) put in %s\n' "$magnets" "$watch/"; fi
    if ((count)); then
        ok 'Torrents put back: %s (through %s).' "$count" "$watch/"
        say '  Each one is checked against the files already there, then goes on (from zero without them).'
        say '  Not kept: pauses, files left out, statistics (sent, ratio).'
    fi
    if ((magnets)); then
        ok 'Magnet links put back: %s (through %s): Transmission asks the other peers for their metadata.' "$magnets" "$watch/"
    fi
    if ((${#by_hand[@]})); then
        (umask 077 && printf '%s\n' "${by_hand[@]}" >"$RESTORE_MAGNETS_FILE")
        log_print '%s magnet link(s) saved in %s (Transmission 3 does not read them in watch/)\n' "${#by_hand[@]}" "$RESTORE_MAGNETS_FILE"
        warn 'Magnet links to add again by hand in the web interface: %s (this Transmission does not read them in %s). They are in:' \
            "${#by_hand[@]}" "$watch/"
        printf '  %s\n' "$RESTORE_MAGNETS_FILE" >&2
    fi
}

# restore_watch_write FILE < CONTENT — a file put in watch/ by the account of
# Transmission, written aside then renamed (see restore_transmission_state)
restore_watch_write() {
    runuser -u "$TRANSMISSION_USER" -- sh -c 'umask 022 && t=$(mktemp "$1.XXXXXX") || exit 1
        if cat >"$t" && chmod 644 "$t" && mv -f "$t" "$1"; then exit 0; fi
        rm -f "$t"
        exit 1' sh "$1" 2>>"$APP_LOG"
}

# magnet_link_read FILE → the magnet link it holds: one line « magnet:?… »,
# printable ASCII without spaces, 64 KB at most. Status 1 for anything else.
magnet_link_read() {
    local link="" rest="" size
    size=$(stat -c %s -- "$1") || return 1
    ((size <= 65536)) || return 1
    {
        IFS= read -r link || true
        IFS= read -r rest || true
    } <"$1"
    [[ -z $rest ]] || return 1
    LC_ALL=C grep -qxE 'magnet:\?[!-~]+' <<<"$link" || return 1
    printf '%s' "$link"
}

# First entry of the archive that is neither a file nor a folder (link, device,
# hard link…), apart from the links of Let's Encrypt to its own certificates
# (live/NAME/cert.pem → ../../archive/NAME/cert1.pem). A file that could be
# run is refused too: execute bit, or setuid, setgid or sticky bit (tar, run
# by root, keeps them; seedtunnel saves none). Nothing: all fine.
backup_unsafe_entry() {
    local entries
    entries=$(tar -tvzf "$1" 2>>"$APP_LOG") || return 1
    awk '
        { type = substr($1, 1, 1); bits = substr($1, 2, 9); name = $6 }
        type == "-" && bits !~ /[xsStT]/ { next }
        type == "d" && bits !~ /[sStT]/ { next }
        type == "l" && NF == 8 && $7 == "->" &&
            name ~ /^etc\/letsencrypt\/live\/[^\/]+\/[^\/]+$/ &&
            $8 ~ /^\.\.\/\.\.\/archive\/[^\/]+\/[^\/]+$/ &&
            substr($8, 15) !~ /(^|\/)\.\.?(\/|$)/ { next }
        { print name; exit }' <<<"$entries"
}

# Names of the settings a settings file may hold: those seedtunnel writes
# there. Nothing for another file.
backup_state_names() {
    case ${1##*/} in
        vpn.conf) printf 'VPN_PORT|VPN_PUBLIC_ADDRESS|VPN_DNS|VPN_OUT_INTERFACE' ;;
        seedbox.conf | seedbox.secrets)
            printf 'SEEDBOX_(USER|DOMAIN|DATA_DIR|CERTIFICATE|LETSENCRYPT|LETSENCRYPT_SERVER|SFTP_PASSWORD|HASH_SYSTEM|HASH_WEB|HASH_TRANSMISSION)'
            ;;
        firewall.conf) printf 'FIREWALL_ENABLED' ;;
        links.conf) printf 'LINKS_CERTIFICATE' ;;
        *.env) printf 'CLIENT_(NUMBER|PUBLIC_KEY|PRESHARED_KEY|PRIVATE_KEY)' ;;
    esac
}

# First settings file (read by « . ») under the folder $1 that could run
# something, or change a variable of seedtunnel other than its own settings
# (PATH, APP_DIR…). Nothing: all fine.
backup_unsafe_state_file() {
    local file names
    # only the files read by « . »: vpn.conf, seedbox.conf, seedbox.secrets,
    # firewall.conf, links.conf, vpn/clients/*.env (vpn/clients/*.conf are WireGuard files,
    # never read by bash)
    for file in "$1"/*.conf "$1"/*.secrets "$1"/vpn/clients/*.env; do
        [[ -e $file || -L $file ]] || continue
        names=$(backup_state_names "$file")
        if [[ ! -f $file || -z $names ]] || ! state_file_is_safe "$file" "$names"; then
            printf '%s' "$file"
            return 0
        fi
    done
}

# restore_bad_name FOLDER — the first file of the settings of the backup
# (FOLDER: its etc/seedtunnel) whose name seedtunnel would not have given, as
# in the archive, quoted (a name may hold a line break): a file of a client of
# the VPN (vpn/clients/*.env, *.conf) whose name is not one a client may have
# (it goes into wg0.conf, read as root by wg-quick: after a line break,
# « PostUp = … » would be a command); anywhere, a line break or another
# control character. Nothing: all fine.
restore_bad_name() {
    local dir=$1 path name
    while IFS= read -r -d '' path; do
        path=${path#"$dir/"}
        name=${path##*/}
        if [[ $path == *[[:cntrl:]]* ]] || { [[ $path == "vpn/clients/$name" && $name =~ \.(env|conf)$ ]] \
            && ! vpn_is_valid_client_name "${name%.*}"; }; then
            printf '%q' "etc/seedtunnel/$path"
            return 0
        fi
    done < <(find "$dir" -mindepth 1 -print0 2>/dev/null)
}

# restore_setting_ok NAME VALUE — is VALUE one that seedtunnel could have
# written for NAME? The same checks as at an installation: a backup made by
# someone else must not bring a path, an account or a name that seedtunnel
# would have refused.
restore_setting_ok() {
    local value=$2
    case $1 in
        VPN_PORT) is_valid_port "$value" ;;
        VPN_PUBLIC_ADDRESS) vpn_is_valid_address "$value" ;;
        VPN_DNS) vpn_is_valid_dns "$value" ;;
        VPN_OUT_INTERFACE) [[ -z $value || $value =~ ^[A-Za-z0-9_.@-]{1,15}$ ]] ;;
        SEEDBOX_USER) seedbox_is_valid_user "$value" ;;
        SEEDBOX_DOMAIN) seedbox_is_valid_domain "$value" ;;
        # its warning (on the error output) says why
        SEEDBOX_DATA_DIR) seedbox_check_data_dir "$value" >/dev/null ;;
        SEEDBOX_CERTIFICATE) [[ $value =~ ^(selfsigned|letsencrypt|staging)$ ]] ;;
        SEEDBOX_LETSENCRYPT) [[ $value =~ ^(auto|yes|no)$ ]] ;;
        SEEDBOX_LETSENCRYPT_SERVER) [[ $value =~ ^(production|staging)$ ]] ;;
        SEEDBOX_SFTP_PASSWORD) [[ $value =~ ^(yes|no)$ ]] ;;
        SEEDBOX_HASH_*) [[ $value =~ ^[A-Za-z0-9./\$!*{}=+-]*$ ]] ;;
        FIREWALL_ENABLED) [[ $value =~ ^[01]$ ]] ;;
        LINKS_CERTIFICATE) [[ $value =~ ^(selfsigned|letsencrypt)$ ]] ;;
        CLIENT_NUMBER) [[ $value =~ ^[1-9][0-9]{0,2}$ ]] && ((value <= 253)) ;;
        CLIENT_PUBLIC_KEY | CLIENT_PRESHARED_KEY | CLIENT_PRIVATE_KEY) is_wg_key "$value" ;;
        *) return 1 ;;
    esac
}

# restore_bad_setting FOLDER — the first value of the settings of the backup
# (FOLDER: its etc/seedtunnel) that seedtunnel would not have written: its
# name, a tab, its file (« VPN_PORT<tab>etc/seedtunnel/vpn.conf »); or the key
# of the VPN server if it is not one key alone (it goes into wg0.conf, where
# a second line could be a command). Nothing: all fine. The
# files were checked before (backup_unsafe_state_file): reading them runs
# nothing, and in a subshell, the settings of this server stay as they are.
restore_bad_setting() (
    local dir=$1 file name bad key
    for file in "$dir"/vpn.conf "$dir"/seedbox.conf "$dir"/seedbox.secrets "$dir"/firewall.conf "$dir"/links.conf "$dir"/vpn/clients/*.env; do
        [[ -f $file ]] || continue
        bad=$(
            # shellcheck source=/dev/null
            . "$file"
            while IFS= read -r name; do
                if ! restore_setting_ok "$name" "${!name-}"; then
                    printf '%s' "$name"
                    break
                fi
            done < <(grep -oE '^[A-Z_]+=' "$file" | tr -d =)
        )
        if [[ -n $bad ]]; then
            printf '%s\tetc/seedtunnel/%s' "$bad" "${file#"$dir/"}"
            return 0
        fi
    done
    if [[ -e $dir/vpn/server.key || -L $dir/vpn/server.key ]]; then
        key=""
        if [[ -f $dir/vpn/server.key ]]; then key=$(<"$dir/vpn/server.key"); fi
        if ! is_wg_key "$key"; then printf 'PrivateKey\tetc/seedtunnel/vpn/server.key'; fi
    fi
)

# First problem in the files of Let's Encrypt of the backup (FOLDER: its
# etc/letsencrypt). certbot runs the commands of the renewal file of a
# certificate as root, twice a day, and writes where it says: only the
# reload of nginx, and the paths seedtunnel uses. Nothing: all fine.
restore_letsencrypt_unsafe() {
    local file="$1/renewal/$LETSENCRYPT_CERT_NAME.conf" line key value section="" live
    [[ -e $file || -L $file ]] || return 0
    live="$LETSENCRYPT_ROOT/live/$LETSENCRYPT_CERT_NAME"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if [[ $line =~ ^[[:space:]]*\[ ]]; then
            section=${line//[[:space:]]/}
            continue
        fi
        [[ $line == *=* ]] || continue
        key=${line%%=*}
        key=${key//[[:space:]]/}
        value=${line#*=}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        if [[ $section == "[[webroot_map]]" ]]; then
            [[ $value == "$LETSENCRYPT_WEBROOT" ]] || {
                printf '%s' "$key"
                return 0
            }
            continue
        fi
        case $key in
            *hook*) [[ $key =~ ^(renew_hook|deploy_hook)$ && $value == "systemctl reload nginx" ]] ;;
            installer) [[ $value == None ]] ;;
            authenticator) [[ $value == webroot ]] ;;
            webroot_path) [[ $value == "$LETSENCRYPT_WEBROOT" || $value == "$LETSENCRYPT_WEBROOT," ]] ;;
            archive_dir) [[ $value == "$LETSENCRYPT_ROOT/archive/$LETSENCRYPT_CERT_NAME" ]] ;;
            cert | privkey | chain | fullchain) [[ $value == "$live/$key.pem" ]] ;;
            # folders where certbot would write its files: never set by seedtunnel
            config_dir | work_dir | logs_dir) false ;;
            *) true ;;
        esac || {
            printf '%s' "$key"
            return 0
        }
    done <"$file"
}

# restore_letsencrypt FOLDER — from the files of Let's Encrypt of the backup,
# only the certificate of seedtunnel and the account goes back: the other
# certificates of this server, and the commands run at a renewal (renewal-
# hooks), are left alone
restore_letsencrypt() {
    local from=$1 part parent
    [[ -d $from ]] || return 0
    install -d -m 755 "$LETSENCRYPT_ROOT"
    # the folders as certbot makes them: live, archive and accounts for root
    # only, renewal readable
    for part in "live/$LETSENCRYPT_CERT_NAME" "archive/$LETSENCRYPT_CERT_NAME" "renewal/$LETSENCRYPT_CERT_NAME.conf" accounts; do
        [[ -e $from/$part ]] || continue
        parent=$LETSENCRYPT_ROOT
        case $part in
            renewal/*)
                parent+=/renewal
                install -d -m 755 "$parent"
                ;;
            */*)
                parent+=/${part%%/*}
                install -d -m 700 "$parent"
                ;;
        esac
        cp -a "$from/$part" "$parent/"
    done
}

# restore_check_system FOLDER — a backup made on another system (Debian ↔
# Ubuntu, another version) is said, nothing more: the paths are the same, and
# a restore from each of the 4 systems to the others was done on real
# servers. A backup that does not say its system: nothing said.
restore_check_system() {
    local file="$1/etc/seedtunnel/system" system=""
    [[ -f $file ]] || return 0
    IFS= read -r -n 40 system <"$file" || true
    system=${system//[^a-z0-9. ]/}
    [[ -n $system && $system != "$APP_OS_ID $APP_OS_VERSION" ]] || return 0
    say 'Backup made on %s, restored on %s.' "${system^}" "${APP_OS_ID^} $APP_OS_VERSION"
}

# restore_has_settings FOLDER — the settings in place hold something to go
# back to. A new server only has its language, its list of packages and its
# system: replaced by those of the backup, they are not kept aside.
restore_has_settings() {
    [[ -n $(find "$1" -mindepth 1 -maxdepth 1 ! -name packages ! -name language ! -name system \
        ! -name backup.downloaded 2>/dev/null || true) ]]
}

# The settings a finished restore replaced, still kept in /etc (old keys,
# password hashes, passphrase): never deleted without being asked
restore_leftovers() {
    local folder
    for folder in "$APP_STATE_DIR".before-restore-*; do
        if [[ -d $folder && ! -L $folder && ${folder##*.before-restore-} =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
            printf '%s\n' "$folder"
        fi
    done
}

# Date of the restore that left FOLDER (…before-restore-YYYYMMDD-HHMMSS), as in
# the list of the backups: « 2026-11-13 07:24 »
restore_leftover_date() {
    local stamp=${1##*.before-restore-}
    printf '%s-%s-%s %s:%s' "${stamp:0:4}" "${stamp:4:2}" "${stamp:6:2}" "${stamp:9:2}" "${stamp:11:2}"
}

# The dates of the restores whose settings are still kept, « 2026-11-13 06:05,
# 2026-11-13 07:24 »; empty if none, or during a restore cut short (they are
# its way back: not to be deleted then)
restore_leftovers_dates() {
    local folder dates=""
    if restore_interrupted; then return 0; fi
    while IFS= read -r folder; do
        dates+="${dates:+, }$(restore_leftover_date "$folder")"
    done < <(restore_leftovers)
    printf '%s' "$dates"
}

# restore_clean — « seedtunnel restore clean », and My backups in the menu:
# deletes the settings kept by finished restores (old keys, passwords,
# passphrase), after a red frame, « no » by default. Only the folders
# seedtunnel made (their exact name, no link); never during a restore cut
# short.
restore_clean() {
    local folder dates
    local -a kept
    WENT_BACK=0
    if restore_interrupted; then
        die 'A restore did not finish: the settings it replaced are its way back, they stay. See  seedtunnel doctor'
    fi
    mapfile -t kept < <(restore_leftovers)
    if ((!${#kept[@]})); then
        ok 'No settings kept by a restore: nothing to delete.'
        return 0
    fi
    dates=$(restore_leftovers_dates)
    if ((${#kept[@]} == 1)); then
        danger "$(t 'Delete the old settings')" \
            "$(t 'The settings replaced by the restore of %s, kept in case it had to be undone: old keys of the VPN, passwords, passphrase.' "$dates")" \
            "$(t 'Once deleted, the settings from before the restore cannot come back.')"
    else
        danger "$(t 'Delete the old settings')" \
            "$(t 'The settings replaced by %s restores (%s), kept in case one had to be undone: old keys of the VPN, passwords, passphrase.' "${#kept[@]}" "$dates")" \
            "$(t 'Once deleted, the settings from before the restores cannot come back.')"
    fi
    if ! confirm 'Delete them?' n; then
        WENT_BACK=1
        return 0
    fi
    for folder in "${kept[@]}"; do
        run "$(t 'Deleting %s' "$folder")" rm -rf -- "$folder" "$folder.outside" "$folder.undo"
    done
    ok 'Old settings deleted.'
}

# restore_cli [FILE | clean] — « seedtunnel restore »: without a file, the
# list of the backups found, as in the menu (in a terminal only); « clean »:
# the settings kept by finished restores deleted
restore_cli() {
    local file=${1-}
    if [[ $file == clean ]]; then
        restore_clean
        return 0
    fi
    if [[ -z $file ]]; then
        stdin_is_terminal || die 'Usage: seedtunnel restore FILE'
        # the list asks which backup, as in the menu (seen on a real server:
        # « Question asked outside interactive mode » without it)
        INTERACTIVE=1
        banner
        section 'Restore a backup'
        # ufw on: said before the choice of the file, not after it
        ufw_refuse
        backup_pick_file file || return 0
    fi
    restore_main "$file"
}

restore_main() {
    local file=${1-} list bad stamp was=$INTERACTIVE kept_passphrase=0 kept_firewall=0 kept_links=0 kept previous="" tries=0
    WENT_BACK=0
    [[ -n $file ]] || die 'Usage: seedtunnel restore FILE'
    [[ -r $file ]] || die 'File not found: %s' "$file"
    banner
    section 'Restore a backup'
    ufw_refuse
    if ! backup_read_passphrase 0; then
        WENT_BACK=1
        return 0
    fi
    BACKUP_TMP_DIR=$(mktemp -d)
    # the decrypted archive holds secrets: deleted whatever happens (an error
    # that stops the script, Ctrl+C)
    trap 'restore_unfinished; backup_cleanup' EXIT
    trap 'exit 130' INT TERM
    # its errors (« bad decrypt ») go to the log under a title of their own
    while log_title 'Decrypting %s' "${file##*/}" \
        && ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$file" -out "$BACKUP_TMP_DIR/backup.tar.gz" \
            -pass fd:3 3<<<"$BACKUP_PASSPHRASE" 2>>"$APP_LOG"; do
        if [[ -n $OPT_PASSPHRASE_FILE ]] || ! stdin_is_terminal; then
            backup_cleanup
            die 'Cannot decrypt: wrong passphrase or damaged file.'
        fi
        # typed in a terminal: asked again, 3 tries as sudo, or back. What
        # was pasted with it is dropped (seen on a real server: 8 lines of
        # a text pasted by mistake, 8 tries in 8 seconds)
        input_drop
        tries=$((tries + 1))
        if ((tries >= 3)); then
            backup_cleanup
            die 'Cannot decrypt after %s tries: wrong passphrase or damaged file. Nothing was changed.' "$tries"
        fi
        warn 'Cannot decrypt: wrong passphrase or damaged file.'
        if ! backup_read_passphrase 0; then
            backup_cleanup
            trap - EXIT INT TERM
            WENT_BACK=1
            return 0
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
        die 'Archive refused: "%s" is a link, a program or a special file' "$bad"
    fi
    mkdir "$BACKUP_TMP_DIR/x"
    # every file to root: an account of this server must not get a file of
    # seedtunnel because the archive says so
    run 'Extracting the archive' tar -xzf "$BACKUP_TMP_DIR/backup.tar.gz" --no-same-owner -C "$BACKUP_TMP_DIR/x"
    # The names of the clients of the VPN go into wg0.conf: only the names
    # seedtunnel gives
    bad=$(restore_bad_name "$BACKUP_TMP_DIR/x/etc/seedtunnel")
    if [[ -n $bad ]]; then
        backup_cleanup
        die 'Archive refused: unexpected path "%s"' "$bad"
    fi
    # The settings are read by « . »: nothing in them may run a command
    bad=$(backup_unsafe_state_file "$BACKUP_TMP_DIR/x/etc/seedtunnel")
    if [[ -n $bad ]]; then
        # named as in the archive (backup_cleanup empties $BACKUP_TMP_DIR)
        bad=${bad#"$BACKUP_TMP_DIR/x/"}
        backup_cleanup
        die 'Archive refused: %s holds something else than settings (it could run commands)' "$bad"
    fi
    # Their values as at an installation, before anything is replaced
    bad=$(restore_bad_setting "$BACKUP_TMP_DIR/x/etc/seedtunnel")
    if [[ -z $bad && -d $BACKUP_TMP_DIR/x/etc/letsencrypt ]]; then
        bad=$(restore_letsencrypt_unsafe "$BACKUP_TMP_DIR/x/etc/letsencrypt")
        if [[ -n $bad ]]; then bad+=$'\t'"etc/letsencrypt/renewal/$LETSENCRYPT_CERT_NAME.conf"; fi
    fi
    if [[ -n $bad ]]; then
        backup_cleanup
        die 'Archive refused: unexpected value of %s in %s' "${bad%%$'\t'*}" "${bad#*$'\t'}"
    fi
    restore_check_server "$BACKUP_TMP_DIR/x"
    restore_check_system "$BACKUP_TMP_DIR/x"
    say 'The backup contains:'
    if grep -qx 'etc/seedtunnel/vpn.conf' <<<"$list"; then say '  - the VPN and its clients'; fi
    if grep -qx 'etc/seedtunnel/seedbox.conf' <<<"$list"; then say '  - the seedbox (settings, passwords, certificates)'; fi
    if grep -q '/transmission-daemon/torrents' <<<"$list"; then say '  - the list of torrents'; fi
    if grep -qx 'etc/seedtunnel/firewall.conf' <<<"$list"; then say '  - the firewall'; fi
    if [[ -n $RESTORE_RENAME_FROM ]]; then
        echo
        say 'The SFTP account %s takes back the name of the backup: %s.' "$RESTORE_RENAME_FROM" "$RESTORE_RENAME_TO"
    fi
    echo
    danger "$(t 'Restore a backup')" "$(t 'The current settings of seedtunnel are replaced by those of the backup (a copy of them is kept in /etc).')"
    if ! confirm 'Restore? The current settings of seedtunnel will be replaced' n; then
        backup_cleanup
        trap - EXIT INT TERM
        WENT_BACK=1
        return 0
    fi
    echo
    stamp=$(date +%Y%m%d-%H%M%S)
    # the list of the packages installed by seedtunnel, and the last download of
    # a backup, describe this server, not the one that was backed up: they stay
    for kept in packages backup.downloaded; do
        rm -f "$BACKUP_TMP_DIR/x/etc/seedtunnel/$kept"
        if [[ -f $APP_STATE_DIR/$kept ]]; then cp -p "$APP_STATE_DIR/$kept" "$BACKUP_TMP_DIR/x/etc/seedtunnel/"; fi
    done
    # a weekly backup brought by the backup starts on this server today: the
    # date of its passphrase says since when it is on (its backups stayed on
    # the other server)
    if [[ -f $BACKUP_TMP_DIR/x/etc/seedtunnel/backup.passphrase ]]; then touch "$BACKUP_TMP_DIR/x/etc/seedtunnel/backup.passphrase"; fi
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
    # The site of the links of this server stays too when the backup has
    # neither one nor a seedbox (whose site would take its place): nginx keeps
    # serving it, and without its settings seedtunnel would no longer see it
    if [[ ! -e $BACKUP_TMP_DIR/x/etc/seedtunnel/links.conf && ! -e $BACKUP_TMP_DIR/x/etc/seedtunnel/seedbox.conf ]] \
        && links_site_on && [[ -f $BACKUP_TMP_DIR/x/etc/seedtunnel/vpn.conf ]]; then
        cp -p "$LINKS_CONF_FILE" "$BACKUP_TMP_DIR/x/etc/seedtunnel/"
        kept_links=1
    fi
    # from here on, a restore cut short is said by « doctor » and the menu
    if restore_has_settings "$APP_STATE_DIR"; then
        printf '%s\n' "$APP_STATE_DIR.before-restore-$stamp" >"$RESTORE_MARKER"
        mv "$APP_STATE_DIR" "$APP_STATE_DIR.before-restore-$stamp"
        RESTORE_PREVIOUS="$APP_STATE_DIR.before-restore-$stamp"
        warn 'Previous settings moved to %s' "$RESTORE_PREVIOUS"
        restore_keep_outside "$RESTORE_PREVIOUS"
    else
        printf 'none\n' >"$RESTORE_MARKER"
        rm -rf "$APP_STATE_DIR"
        RESTORE_PREVIOUS=none
    fi
    # the account renamed since the backup takes back its name, once the way
    # back knows it; seedbox_apply below resumes it under that name
    if [[ -n $RESTORE_RENAME_FROM ]]; then seedbox_rename_account "$RESTORE_RENAME_FROM" "$RESTORE_RENAME_TO"; fi
    # -T: into $APP_STATE_DIR itself, even if something created it again
    # meanwhile (never into $APP_STATE_DIR/seedtunnel)
    cp -aT "$BACKUP_TMP_DIR/x/etc/seedtunnel" "$APP_STATE_DIR"
    # the fingerprints are those of the files of the server backed up, not of
    # this one: without them, nothing is taken for a change by hand
    written_forget
    # the rules loaded are those of this server, whatever their file says
    if firewall_enabled; then pending_set firewall; fi
    restore_letsencrypt "$BACKUP_TMP_DIR/x/etc/letsencrypt"
    if [[ -d $BACKUP_TMP_DIR/x/etc/ssh/seedtunnel_authorized_keys ]]; then
        cp -a "$BACKUP_TMP_DIR/x/etc/ssh/seedtunnel_authorized_keys" /etc/ssh/
    fi

    # Everything is installed again from the restored settings, without questions
    i18n_init
    vpn_load
    seedbox_load
    links_load
    INTERACTIVE=0
    if vpn_installed; then
        vpn_check_kernel
        base_setup
        vpn_apply
    fi
    if seedbox_installed; then
        base_setup
        # the torrents and the settings of Transmission go back while it is
        # stopped for its settings (seedbox_apply_transmission)
        TRANSMISSION_RESTORE_FROM="$BACKUP_TMP_DIR/x"
        seedbox_apply
        TRANSMISSION_RESTORE_FROM=""
    fi
    if links_site_on; then links_apply; fi
    if firewall_enabled; then firewall_enable; fi
    if [[ -r $BACKUP_PASSPHRASE_FILE ]]; then
        backup_auto_install_units
    elif backup_auto_enabled; then
        # its timer on, but no passphrase anywhere: it could only fail
        backup_auto_disable
        warn 'Neither the backup restored nor this server has a passphrase for the weekly backup: it was turned off. To turn it on again:  seedtunnel backup auto on'
    fi
    # finished: the way back of a restore cut short is no longer needed (the
    # previous settings stay where they were moved, until deleted by hand)
    if [[ $RESTORE_PREVIOUS != none ]]; then
        rm -rf "$RESTORE_PREVIOUS.outside" "$RESTORE_PREVIOUS.undo"
        previous=$RESTORE_PREVIOUS
    fi
    RESTORE_PREVIOUS=""
    RESTORE_RENAME_FROM=""
    RESTORE_RENAME_TO=""
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
    if ((kept_links)); then
        ok 'The site of the links of this server stays (the backup restored has none).'
    fi
    ok 'Restore finished.'
    if [[ -n $previous ]]; then
        say 'The settings it replaced are kept in %s (old keys, passwords, passphrase). Once everything works, delete them in Backup / restore › My backups, or:' "$previous"
        printf '  seedtunnel restore clean\n'
    fi
    if seedbox_installed; then text restore_after; fi
}
