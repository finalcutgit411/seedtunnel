#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Short operation scopes, independent of the main lock held by idle menus.
# Callers declare local OPERATION_FD=${OPERATION_FD-} and an empty owner variable.
# Only the owning frame releases a descriptor; nested Bash calls borrow it.
# No scope spans a detached job. The file is stable across restore and never
# unlinked; ExecStartPre must never wait for this lock.
APP_OPERATION_LOCK="/run/seedtunnel.operation.lock"

# operation_begin OWNER_VARIABLE [try] — 0 acquired/borrowed, 75 busy (try),
# 1 I/O or locking error. All steps are checked, even when called conditionally.
operation_begin() {
    local _op_begin_fd _op_begin_mask _op_begin_status=0
    printf -v "$1" '%s' ''
    if [[ ${OPERATION_FD-} =~ ^[0-9]+$ && /proc/self/fd/${OPERATION_FD-} -ef $APP_OPERATION_LOCK ]] \
        && flock -n "$OPERATION_FD"; then
        return 0
    fi
    _op_begin_mask=$(umask) || return 1
    umask 077 || return 1
    if ! exec {_op_begin_fd}>>"$APP_OPERATION_LOCK"; then
        umask "$_op_begin_mask" || true
        warn 'Cannot open operation lock %s.' "$APP_OPERATION_LOCK"
        return 1
    fi
    if ! umask "$_op_begin_mask" || ! chmod 600 "$APP_OPERATION_LOCK"; then
        exec {_op_begin_fd}>&- || true
        warn 'Cannot prepare operation lock %s.' "$APP_OPERATION_LOCK"
        return 1
    fi
    if [[ ${2-} == try ]]; then
        flock -n -E 75 "$_op_begin_fd" || _op_begin_status=$?
    else
        flock "$_op_begin_fd" || _op_begin_status=$?
    fi
    if ((_op_begin_status)); then
        exec {_op_begin_fd}>&- || true
        if ((_op_begin_status != 75)); then warn 'Cannot acquire operation lock %s.' "$APP_OPERATION_LOCK"; fi
        return "$_op_begin_status"
    fi
    OPERATION_FD=$_op_begin_fd
    printf -v "$1" '%s' "$_op_begin_fd"
}

operation_end() {
    local _op_end_fd=$1 _op_end_status=0
    [[ -n $_op_end_fd ]] || return 0
    [[ $_op_end_fd =~ ^[0-9]+$ ]] || return 1
    flock -u "$_op_end_fd" || _op_end_status=$?
    exec {_op_end_fd}>&- || _op_end_status=1
    OPERATION_FD=""
    if ((_op_end_status)); then
        warn 'Cannot release operation lock %s.' "$APP_OPERATION_LOCK"
        return 1
    fi
}

# A prestart during recovery may probe, but never wait for, the parent's lock.
# 0 = operation active; 1 = free; 2 = observation unavailable. A fresh OFD is
# essential: this is a probe, not a reentrant borrow of a caller's scope.
operation_in_progress() {
    (
        local OPERATION_FD="" _op_probe_owner="" _op_probe_status=0
        operation_begin _op_probe_owner try || _op_probe_status=$?
        if ((_op_probe_status == 75)); then return 0; fi
        if ((_op_probe_status)); then return 2; fi
        operation_end "$_op_probe_owner" || return 2
        return 1
    )
}
