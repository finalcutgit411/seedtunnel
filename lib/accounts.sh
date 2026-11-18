#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Human-account primitives; no engine or seedbox state is read here.
# Load after common/i18n. Callers own credentials and SFTP policy.

accounts_ensure() {
    local user=$1 engine_group=$2
    if ! id "$user" &>/dev/null; then
        run "$(t 'Creating the user %s' "$user")" useradd --no-create-home --home-dir / \
            --shell /usr/sbin/nologin --user-group --groups "$engine_group" \
            --comment "seedtunnel seedbox" "$user"
    fi
    if [[ " $(id -nG "$user") " != *" $engine_group "* ]]; then
        usermod -aG "$engine_group" "$user"
    fi
}

accounts_restore_hash() {
    local user=$1 hash=$2 current
    current=$(getent shadow "$user" | cut -d: -f2)
    if [[ $current != "$hash" ]]; then
        printf '%s:%s\n' "$user" "$hash" | chpasswd -e
    fi
}

# A suspended account cannot log in at all, by password or by key (expired
# account), and its sessions are closed: used while its SFTP restrictions are
# not in force. Expiry « 1 » (2 January 1970) marks a suspension by seedtunnel.
# Checked, not assumed: fails if the account is not expired afterwards, or
# still has processes.
accounts_suspend() {
    local user=$1 i
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
accounts_resume() {
    local user=$1
    if [[ $(getent shadow "$user" 2>/dev/null | cut -d: -f8 || true) == 1 ]]; then
        usermod --expiredate '' "$user" >>"$APP_LOG" 2>&1 || true
        [[ $(getent shadow "$user" 2>/dev/null | cut -d: -f8 || true) != 1 ]] || return 1
    fi
}

# Idempotent removal, after sessions close. 0 absent/deleted, 1 still present.
accounts_delete() {
    local user=$1 attempt
    id "$user" &>/dev/null || return 0
    for attempt in 1 2 3; do
        pkill -KILL -u "$user" >>"$APP_LOG" 2>&1 || true
        if userdel "$user" >>"$APP_LOG" 2>&1 || ! id "$user" &>/dev/null; then return 0; fi
        sleep 1
    done
    return 1
}

# Raw identity operations; the SFTP coordinator owns suspension and rollback.
accounts_group_exists() { getent group "$1" >/dev/null; }
accounts_rename_login() { usermod --login "$2" "$1" >>"$APP_LOG" 2>&1; }
accounts_rename_group() { groupmod --new-name "$2" "$1" >>"$APP_LOG" 2>&1; }
