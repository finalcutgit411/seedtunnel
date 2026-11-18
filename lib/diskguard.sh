#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Common disk guard: thresholds, recovery record and systemd timer resources.
# Feature adapters supply data path, labels and fixed engine callbacks.
# A service stopped without a guard record is never automatically started.
# Timer/maintenance concurrency is a separate contract; no lock is taken here.

DISKGUARD_STOP_BELOW_GB=3
DISKGUARD_START_ABOVE_GB=5
# present while the guard owns an automatic recovery request (/run: emptied at boot)
DISKGUARD_MARKER="/run/seedtunnel-diskguard.stopped"
DISKGUARD_SERVICE="/etc/systemd/system/seedtunnel-diskguard.service"
DISKGUARD_TIMER="/etc/systemd/system/seedtunnel-diskguard.timer"

diskguard_stopped() { [[ -e $DISKGUARD_MARKER ]]; }

# Parse the complete record, not just a valid-looking first line. The timestamp
# is audit data, not an expiry: recovery authority lasts until cleared or reboot.
diskguard_marker_state() {
    local _dg_record _dg_pattern='^[0-9]+( (failed|unconfirmed))?$'
    if ! _dg_record=$(cat -- "$1" 2>/dev/null); then
        printf '%s' invalid
        return 0
    fi
    if [[ ! $_dg_record =~ $_dg_pattern ]]; then
        printf '%s' invalid
        return 0
    fi
    case $_dg_record in
        *' failed') printf '%s' failed ;;
        *' unconfirmed') printf '%s' unconfirmed ;;
        *) printf '%s' space ;;
    esac
}

diskguard_start_failed() { [[ $(diskguard_marker_state "${1:-$DISKGUARD_MARKER}") == failed ]]; }
diskguard_restart_unconfirmed() { [[ $(diskguard_marker_state "${1:-$DISKGUARD_MARKER}") == unconfirmed ]]; }
diskguard_state_invalid() {
    [[ -e ${1:-$DISKGUARD_MARKER} ]] && [[ $(diskguard_marker_state "${1:-$DISKGUARD_MARKER}") == invalid ]]
}

# The free space cannot be read: said loudly (journal, diagnostics), since the
# protection cannot work then. The engine is not stopped for it.
diskguard_cannot_measure() {
    logger -t seedtunnel "Free space of $1 cannot be measured: full disk protection inactive" 2>/dev/null || true
    warn 'Cannot measure the free space of %s: the full disk protection cannot work.' "$1"
}

diskguard_generate_service() {
    cat <<EOF
# Written by seedtunnel — stops the engine when the disk is almost full
[Unit]
Description=seedtunnel: engine stopped when the disk is almost full

[Service]
Type=oneshot
ExecStart=$APP_DIR/seedtunnel.sh diskguard-check
EOF
}

diskguard_generate_timer() {
    cat <<'EOF'
# Written by seedtunnel
[Unit]
Description=seedtunnel: free space check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
}

# Called by seedbox_apply
diskguard_install() {
    local changed=0
    if write_if_changed "$DISKGUARD_SERVICE" 644 root:root diskguard_generate_service; then changed=1; fi
    if write_if_changed "$DISKGUARD_TIMER" 644 root:root diskguard_generate_timer; then changed=1; fi
    if ((changed)); then run 'Reloading systemd' systemctl daemon-reload; fi
    unit_ensure_on 'Enabling the full disk protection' seedtunnel-diskguard.timer
}

diskguard_remove() {
    log_run 'Turning the full disk protection off' systemctl disable --now seedtunnel-diskguard.timer
    rm -f "$DISKGUARD_SERVICE" "$DISKGUARD_TIMER" "$DISKGUARD_MARKER"
    systemctl daemon-reload 2>/dev/null || true
}

# Atomic ownership record. Timestamp-only and "failed" records stay compatible;
# "unconfirmed" means a restart did not yield a readable runtime state.
# Every I/O step is checked, including when called from ExecStartPre's condition.
diskguard_mark() {
    local _dg_mark_path=$1 _dg_mark_state=${2-} _dg_mark_time _dg_mark_tmp
    case $_dg_mark_state in "" | failed | unconfirmed) ;; *) return 1 ;; esac
    _dg_mark_time=$(date +%s) || return 1
    [[ $_dg_mark_time =~ ^[0-9]+$ ]] || return 1
    _dg_mark_tmp=$(umask 077 && mktemp "$_dg_mark_path.tmp.XXXXXX") || return 1
    if ! printf '%s%s\n' "$_dg_mark_time" "${_dg_mark_state:+ $_dg_mark_state}" >"$_dg_mark_tmp" \
        || ! chmod 600 "$_dg_mark_tmp" || ! mv -f -- "$_dg_mark_tmp" "$_dg_mark_path"; then
        rm -f -- "$_dg_mark_tmp" || true
        return 1
    fi
}

diskguard_clear() { rm -f -- "$1"; }

# Explicit policy inputs; callbacks are fixed internal engine functions, not
# names read from configuration or archives. Runtime: active/not_running/unknown.
diskguard_prestart_for() {
    local _dg_pre_data=$1 _dg_pre_marker=$2 _dg_pre_stop=$3 _dg_pre_name=$4 _dg_pre_free
    if [[ ! $_dg_pre_stop =~ ^[0-9]{1,9}$ ]]; then
        warn 'Invalid disk guard threshold: %s' "$_dg_pre_stop"
        return 1
    fi
    _dg_pre_stop=$((10#$_dg_pre_stop))
    _dg_pre_free=$(disk_free_gb "$_dg_pre_data")
    if [[ ! $_dg_pre_free =~ ^[0-9]{1,16}$ ]]; then
        diskguard_cannot_measure "$_dg_pre_data"
        return 0
    fi
    _dg_pre_free=$((10#$_dg_pre_free))
    if ((_dg_pre_free < _dg_pre_stop)); then
        if ! diskguard_mark "$_dg_pre_marker"; then
            warn 'Cannot record disk guard state in %s; automatic recovery cannot be recorded.' "$_dg_pre_marker"
            return 1
        fi
        logger -t seedtunnel "$_dg_pre_name not started: disk almost full ($_dg_pre_free GB free)" 2>/dev/null || true
        log_title '%s not started: disk almost full (%s GB free).' "$_dg_pre_name" "$_dg_pre_free"
        say '%s not started: disk almost full (%s GB free).' "$_dg_pre_name" "$_dg_pre_free"
        return 1
    fi
    if ! diskguard_clear "$_dg_pre_marker"; then
        warn 'Cannot clear disk guard state in %s.' "$_dg_pre_marker"
        return 1
    fi
}

diskguard_resume_notice() {
    local _dg_notice_marker=$1 _dg_notice_reason=$2 _dg_notice_name=$3 _dg_notice_service=$4 _dg_notice_free=$5
    if ! diskguard_mark "$_dg_notice_marker" "$_dg_notice_reason"; then
        warn 'Cannot record disk guard state in %s; automatic recovery cannot be recorded.' "$_dg_notice_marker"
        return 1
    fi
    if [[ $_dg_notice_reason == unconfirmed ]]; then
        logger -t seedtunnel "$_dg_notice_name restart could not be confirmed" 2>/dev/null || true
        log_title 'Automatic restart of %s could not be confirmed; disk guard state kept.' "$_dg_notice_name"
        warn 'Automatic restart of %s could not be confirmed; disk guard state kept.' "$_dg_notice_name"
    else
        logger -t seedtunnel "$_dg_notice_name does not start again although there is room ($_dg_notice_free GB free)" 2>/dev/null || true
        log_title '%s does not start again although there is room (%s GB free):  journalctl -u %s -n 30' "$_dg_notice_name" "$_dg_notice_free" "$_dg_notice_service"
        warn '%s does not start again although there is room (%s GB free):  journalctl -u %s -n 30' "$_dg_notice_name" "$_dg_notice_free" "$_dg_notice_service"
    fi
}

# DATA MARKER STOP_BELOW START_ABOVE NAME SERVICE START STOP RUNTIME
# A timer tick may only claim an unmarked service after a confirmed stop.
diskguard_check_for() {
    local _dg_data=$1 _dg_marker=$2 _dg_stop=$3 _dg_start=$4 _dg_name=$5 _dg_service=$6
    local _dg_start_fn=$7 _dg_stop_fn=$8 _dg_runtime_fn=$9 _dg_free _dg_runtime _dg_start_status=0
    if [[ ! $_dg_stop =~ ^[0-9]{1,9}$ || ! $_dg_start =~ ^[0-9]{1,9}$ ]]; then
        warn 'Invalid disk guard threshold: %s' "$_dg_stop/$_dg_start"
        return 1
    fi
    _dg_stop=$((10#$_dg_stop)) _dg_start=$((10#$_dg_start))
    _dg_free=$(disk_free_gb "$_dg_data")
    if [[ ! $_dg_free =~ ^[0-9]{1,16}$ ]]; then
        diskguard_cannot_measure "$_dg_data"
        return 0
    fi
    _dg_free=$((10#$_dg_free))
    if [[ -e $_dg_marker ]]; then
        if [[ $(diskguard_marker_state "$_dg_marker") == invalid ]]; then
            warn 'Invalid disk guard record %s; automatic restart suspended.' "$_dg_marker"
            return 1
        fi
        if ((_dg_free >= _dg_start)); then
            "$_dg_start_fn" || _dg_start_status=$?
            _dg_runtime=$("$_dg_runtime_fn") || _dg_runtime=unknown
            if [[ $_dg_runtime == active ]]; then
                if ! diskguard_clear "$_dg_marker"; then
                    warn 'Cannot clear disk guard state in %s.' "$_dg_marker"
                    return 1
                fi
                if ((_dg_start_status)); then
                    warn '%s start reported a failure, although its service is active.' "$_dg_name"
                    return 1
                fi
                logger -t seedtunnel "$_dg_name started again: $_dg_free GB free" 2>/dev/null || true
                log_title '%s started again: %s GB free.' "$_dg_name" "$_dg_free"
                say '%s started again: %s GB free.' "$_dg_name" "$_dg_free"
            elif [[ $_dg_runtime == not_running ]]; then
                diskguard_resume_notice "$_dg_marker" failed "$_dg_name" "$_dg_service" "$_dg_free"
                return $?
            else
                diskguard_resume_notice "$_dg_marker" unconfirmed "$_dg_name" "$_dg_service" "$_dg_free"
                return $?
            fi
        fi
    elif ((_dg_free < _dg_stop)); then
        _dg_runtime=$("$_dg_runtime_fn") || _dg_runtime=unknown
        if [[ $_dg_runtime == active ]]; then
            if ! "$_dg_stop_fn"; then
                warn 'Cannot stop %s on an almost full disk; no automatic restart was authorized.' "$_dg_name"
                return 1
            fi
            _dg_runtime=$("$_dg_runtime_fn") || _dg_runtime=unknown
            if [[ $_dg_runtime != not_running ]]; then
                warn 'Stop of %s could not be confirmed; no automatic restart was authorized.' "$_dg_name"
                return 1
            fi
            if ! diskguard_mark "$_dg_marker"; then
                warn 'Cannot record disk guard state in %s; automatic recovery cannot be recorded.' "$_dg_marker"
                return 1
            fi
            logger -t seedtunnel "$_dg_name stopped: disk almost full ($_dg_free GB free)" 2>/dev/null || true
            log_title '%s stopped: disk almost full (%s GB free).' "$_dg_name" "$_dg_free"
            say '%s stopped: disk almost full (%s GB free).' "$_dg_name" "$_dg_free"
        elif [[ $_dg_runtime != not_running ]]; then
            warn 'State of %s unavailable; disk guard did not change it.' "$_dg_name"
        fi
    fi
    return 0
}
