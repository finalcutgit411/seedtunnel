#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Transmission archive payload. No archive extraction or shared configuration
# here; the coordinator validates the archive before invoking an import.

# Existing archive layout, relative to /. Runtime state is a live copy, not
# a quiescent snapshot. Only include native settings for an installed seedbox.
transmission_export_paths() {
    local include_settings=$1 path settings
    for path in "${TRANSMISSION_STATE_DIR#/}/torrents" "${TRANSMISSION_STATE_DIR#/}/resume"; do
        if [[ -e /$path ]]; then printf '%s\n' "$path"; fi
    done
    if [[ $include_settings == 1 ]] && settings=$(transmission_settings_file) && [[ -f $settings ]]; then
        printf '%s\n' "${settings#/}"
    fi
}

# Trusted, fixed regex fragment; archive contents never supply a pattern.
transmission_archive_pattern() {
    printf '%s' 'var/lib/transmission-daemon/\.config/transmission-daemon/(torrents|resume|settings\.json)|etc/transmission-daemon/settings\.json'
}

# An archive listing on stdin, not the contents of any native file.
transmission_archive_has_items() {
    grep -qE '^var/lib/transmission-daemon/\.config/transmission-daemon/torrents(/|$)'
}

# transmission_import EXTRACTED DATA_DIR MANUAL_MAGNETS — imported only after
# archive validation, with the daemon already stopped by the coordinator.
# Paths and account are backend-owned; destination context is explicit.
# The torrents go back through the watch folder, as new ones: Transmission
# checks each one against the files already there before starting it —
# complete if they were copied back, from zero otherwise. Their progress files
# are not put back: Transmission 3 (Debian 12) does not read those of
# Transmission 4, and a torrent that believes it has its files, on a new server
# without them, stays in error until it is checked by hand.
transmission_import() {
    local -n _tr_import_result=$4
    _tr_import_result=([state]=failed [torrents]=0 [magnets]=0 [rejected]=0 [failed]=0 [manual]=0 [settings]=kept)
    local extracted=$1 source="$1$TRANSMISSION_STATE_DIR" data_dir=$2 manual_magnets=$3
    local settings target torrent count=0 magnets=0 link
    local -a by_hand=()
    local watch="$data_dir/watch"
    for settings in "$extracted/etc/transmission-daemon/settings.json" "$source/settings.json"; do
        if [[ -f $settings && ! -L $settings ]]; then
            # written by the account of Transmission, replaced by renaming
            # (the link of Debian points to the real file, and still does)
            # its message is said: stop there, as die does (not « return »: the
            # error trap would add an « Unexpected error »)
            target=$(transmission_settings_file) || exit 1
            transmission_settings_write "$target" "$settings" || return $?
            _tr_import_result[settings]=restored
            break
        fi
    done
    # a backup without the state of Transmission: the list of the server stays
    if [[ ! -d $source/torrents && ! -d $source/resume ]]; then
        _tr_import_result[state]=complete
        if [[ ${_tr_import_result[settings]} == kept ]]; then _tr_import_result[state]=unchanged; fi
        return 0
    fi
    log_title 'Putting the torrents of the backup back through %s' "$watch/"
    # the list of the server is replaced by the one of the backup (the files
    # downloaded stay where they are)
    # its message is said: stop there, as die does (not « return »: the
    # error trap would add an « Unexpected error »)
    transmission_state_path_safe || exit 1
    rm -rf "${TRANSMISSION_STATE_DIR:?}/torrents" "${TRANSMISSION_STATE_DIR:?}/resume" || return $?
    install -d -m 755 -o "$TRANSMISSION_USER" -g "$TRANSMISSION_USER" "$TRANSMISSION_STATE_DIR" || return $?
    # Written by Transmission's own account, never by root: the SFTP user also
    # writes in watch/, and could put a link there to make root write elsewhere.
    # Written aside, then renamed: a link put under the same name is replaced,
    # never followed (it would lead to a file of Transmission), and Transmission
    # never sees a torrent half-written (it only takes the names in .torrent).
    # Readable by Transmission (a .torrent of root left unreadable is never added).
    for torrent in "$source/torrents"/*.torrent; do
        [[ -f $torrent && ! -L $torrent ]] || continue
        if transmission_import_watch_write "$watch/${torrent##*/}" <"$torrent"; then
            count=$((count + 1))
            _tr_import_result[torrents]=$count
        else
            _tr_import_result[failed]=$((_tr_import_result[failed] + 1))
            warn 'Torrent not put back (details in %s): %s' "$APP_LOG" "${torrent##*/}"
        fi
    done
    # Added by a magnet link, without their metadata yet: Transmission 4 keeps
    # only their link, in HASH.magnet. Transmission 4 reads them in watch/ too; Transmission 3 (Debian
    # 12) does not: they are saved in a file, to add them again by hand.
    for torrent in "$source/torrents"/*.magnet; do
        [[ -f $torrent && ! -L $torrent ]] || continue
        if ! link=$(transmission_magnet_link_read "$torrent"); then
            _tr_import_result[rejected]=$((_tr_import_result[rejected] + 1))
            warn 'Magnet link not put back (unexpected content): %s' "${torrent##*/}"
        elif ! transmission_reads_magnets; then
            by_hand+=("$link")
        elif printf '%s' "$link" | transmission_import_watch_write "$watch/${torrent##*/}"; then
            magnets=$((magnets + 1))
            _tr_import_result[magnets]=$magnets
        else
            _tr_import_result[failed]=$((_tr_import_result[failed] + 1))
            warn 'Magnet link not put back (details in %s): %s' "$APP_LOG" "${torrent##*/}"
        fi
    done
    _tr_import_result[manual]=${#by_hand[@]}
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
        (umask 077 && printf '%s\n' "${by_hand[@]}" >"$manual_magnets") || return $?
        log_print '%s magnet link(s) saved in %s (Transmission 3 does not read them in watch/)\n' "${#by_hand[@]}" "$manual_magnets"
        warn 'Magnet links to add again by hand in the web interface: %s (this Transmission does not read them in %s). They are in:' \
            "${#by_hand[@]}" "$watch/"
        printf '  %s\n' "$manual_magnets" >&2
    fi
    _tr_import_result[state]=complete
    if ((_tr_import_result[rejected] + _tr_import_result[failed] + _tr_import_result[manual])); then
        _tr_import_result[state]=partial
    fi
    log_print 'engine import: %s; torrents=%s magnets=%s rejected=%s failed=%s manual=%s\n' \
        "${_tr_import_result[state]}" "${_tr_import_result[torrents]}" "${_tr_import_result[magnets]}" \
        "${_tr_import_result[rejected]}" "${_tr_import_result[failed]}" "${_tr_import_result[manual]}"
}

# transmission_import_watch_write FILE < CONTENT — a file put in watch/ by the account of
# Transmission, written aside then renamed (see transmission_import)
transmission_import_watch_write() {
    runuser -u "$TRANSMISSION_USER" -- sh -c 'umask 022 && t=$(mktemp "$1.XXXXXX") || exit 1
        if cat >"$t" && chmod 644 "$t" && mv -f "$t" "$1"; then exit 0; fi
        rm -f "$t"
        exit 1' sh "$1" 2>>"$APP_LOG"
}

# transmission_magnet_link_read FILE → the magnet link it holds: one line « magnet:?… »,
# printable ASCII without spaces, 64 KB at most. Status 1 for anything else.
transmission_magnet_link_read() {
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

# transmission_state_path_safe — no link on the way to the state of
# Transmission in a folder that an account other than root can change (the
# account of Transmission owns /var/lib/transmission-daemon and .config):
# root removes and copies this state by this path, and would follow such a
# link elsewhere. A link in a folder of root (/var → …) is the choice of the
# administrator: followed. Checked with Transmission stopped, so that nothing
# of its account runs any more to change the path in between.
transmission_state_path_safe() {
    local path=$TRANSMISSION_STATE_DIR parent owner mode
    while [[ $path == /?* ]]; do
        parent=${path%/*}
        if [[ -L $path ]]; then
            if ! read -r owner mode < <(stat -L -c '%u %a' -- "${parent:-/}" 2>/dev/null) \
                || [[ $owner != 0 ]] || ((8#$mode & 8#022)); then
                err 'The state of Transmission %s is reached through a link (%s) that another account than root can change: seedtunnel does not follow it.' \
                    "$TRANSMISSION_STATE_DIR" "$path"
                return 1
            fi
        fi
        path=$parent
    done
}

# Validated archive root. Read-only preflight, before any service or state change.
transmission_archive_check() {
    local file
    for file in "$1/etc/transmission-daemon/settings.json" "$1$TRANSMISSION_STATE_DIR/settings.json"; do
        if [[ -e $file || -L $file ]]; then
            [[ -f $file && ! -L $file ]] || return 1
            command -v jq >/dev/null 2>&1 || return 2
            jq -e 'type == "object"' "$file" >/dev/null 2>&1 || return 1
        fi
    done
}

# Private local recovery checkpoint, not an importable backup format. The
# final directory appears only after every native copy has succeeded.
transmission_checkpoint_create() {
    local outside=$1 stage="$1/.engine-stage" part settings status
    [[ ! -e $outside/engine && ! -L $outside/engine ]] || return 1
    [[ ! -L $TRANSMISSION_STATE_DIR && (! -e $TRANSMISSION_STATE_DIR || -d $TRANSMISSION_STATE_DIR) ]] || return 1
    install -d -m 700 "$stage" || return $?
    if [[ -e $TRANSMISSION_STATE_DIR || -L $TRANSMISSION_STATE_DIR || -e $TRANSMISSION_ETC_SETTINGS || -L $TRANSMISSION_ETC_SETTINGS ]]; then
        # the status: see the contract at the top of engine.sh
        transmission_stop_for_restore
        status=$?
        if ((status)); then return "$status"; fi
        transmission_state_path_safe || return 1
        settings=$(transmission_settings_file) || return 1
        if [[ -f $settings ]]; then
            transmission_settings_read "$settings" >"$stage/settings.json" || return $?
            chmod 600 "$stage/settings.json" || return $?
        fi
        for part in torrents resume; do
            if [[ -e $TRANSMISSION_STATE_DIR/$part || -L $TRANSMISSION_STATE_DIR/$part ]]; then
                [[ -d $TRANSMISSION_STATE_DIR/$part && ! -L $TRANSMISSION_STATE_DIR/$part ]] || return 1
                cp -a -- "$TRANSMISSION_STATE_DIR/$part" "$stage/" || return $?
            fi
        done
    fi
    (umask 077 && : >"$stage/ready") || return $?
    mv -T -- "$stage" "$outside/engine"
}

# Recheck quiescence under the recovery coordinator's operation scope.
transmission_checkpoint_restore() {
    local checkpoint="$1/engine" part settings status
    [[ -d $checkpoint && ! -L $checkpoint && -f $checkpoint/ready && ! -L $checkpoint/ready ]] || return 1
    [[ ! -L $TRANSMISSION_STATE_DIR && (! -e $TRANSMISSION_STATE_DIR || -d $TRANSMISSION_STATE_DIR) ]] || return 1
    for part in torrents resume; do
        [[ ! -L $checkpoint/$part && (! -e $checkpoint/$part || -d $checkpoint/$part) ]] || return 1
    done
    [[ ! -L $checkpoint/settings.json && (! -e $checkpoint/settings.json || -f $checkpoint/settings.json) ]] || return 1
    # the status: see the contract at the top of engine.sh
    transmission_stop_for_restore
    status=$?
    if ((status)); then return "$status"; fi
    transmission_state_path_safe || return 1
    settings=$(transmission_settings_file) || return 1
    if [[ -f $checkpoint/settings.json && ! -L $checkpoint/settings.json ]]; then
        transmission_settings_write "$settings" "$checkpoint/settings.json" || return $?
    elif [[ -e $settings ]]; then
        runuser -u "$TRANSMISSION_USER" -- rm -f -- "$settings" || return $?
    fi
    for part in torrents resume; do
        rm -rf -- "${TRANSMISSION_STATE_DIR:?}/$part" || return $?
        if [[ -d $checkpoint/$part && ! -L $checkpoint/$part ]]; then
            if [[ ! -d $TRANSMISSION_STATE_DIR ]]; then
                install -d -m 755 -o "$TRANSMISSION_USER" -g "$TRANSMISSION_USER" "$TRANSMISSION_STATE_DIR" || return $?
            fi
            cp -a -- "$checkpoint/$part" "$TRANSMISSION_STATE_DIR/" || return $?
        fi
    done
}

# Emitted from installed code, never from the archive. Paths are shell-quoted.
# prepare runs before restoring shared resources; restore after them.
transmission_recovery_script() {
    case $1 in
        prepare)
            printf 'TRANSMISSION_STATE_DIR=%q\nTRANSMISSION_ETC_SETTINGS=%q\nTRANSMISSION_USER=%q\n' \
                "$TRANSMISSION_STATE_DIR" "$TRANSMISSION_ETC_SETTINGS" "$TRANSMISSION_USER"
            printf '%s\n' 'engine_recovery_stop'
            ;;
        restore) printf 'engine_checkpoint_restore %q\n' "$2" ;;
        *) return 1 ;;
    esac
}
