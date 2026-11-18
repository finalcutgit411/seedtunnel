#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SFTP restrictions, account rename and authorized key files with explicit inputs.
# Load with common/i18n/accounts/ssh_keys. No seedbox or VPN state is read here.
# sftp_apply USER DATA PASSWORD_VARIABLE KEY_DIR CONF PROBE_ADDRESS...
# Internal callers supply validated names/paths and representative probe addresses.

sftp_account_has_keys() {
    [[ -s $2/$1 ]] && grep -q '^ssh-\|^ecdsa-\|^sk-' "$2/$1"
}

# Effective SSH settings for USER ADDRESS, as sshd applies them
sftp_effective_settings() { sshd_settings -C "user=$1,host=$2,addr=$2"; }

# Are all the restrictions written for the account (sftp_generate_conf)
# in force, wherever it connects from? From the server itself, through the
# VPN, from the Internet: a Match Address block could treat them differently.
# The way to log in too: « keys only » must leave no password, not even
# through keyboard-interactive, and the keys must be the ones of seedtunnel.
sftp_rule_applies() {
    local user=$1 data_dir=$2 password=$3 key_dir=$4
    shift 4
    (($#)) || return 1
    local address settings line
    for address in "$@"; do
        settings=$(sftp_effective_settings "$user" "$address")
        grep -qxF "chrootdirectory $data_dir" <<<"$settings" || return 1
        grep -q '^forcecommand internal-sftp' <<<"$settings" || return 1
        for line in 'permittty no' 'allowtcpforwarding no' 'allowagentforwarding no' \
            'allowstreamlocalforwarding no' 'x11forwarding no' 'permittunnel no' \
            "passwordauthentication $password" 'kbdinteractiveauthentication no' \
            'pubkeyauthentication yes'; do
            grep -qxF "$line" <<<"$settings" || return 1
        done
        grep -qxF -e "authorizedkeysfile $key_dir/%u" -e "authorizedkeysfile $key_dir/$user" \
            <<<"$settings" || return 1
    done
}

# Renames the account, its group and its SSH keys, suspended meanwhile (its
# SFTP rule is written for the old name). If a step fails, the steps already
# done are undone: the account keeps its old name, never half renamed.
sftp_rename_account() {
    local old=$1 new=$2 key_dir=$3 group=0
    if ! accounts_suspend "$old"; then
        accounts_resume "$old" || true
        die 'Cannot suspend %s before renaming it (details in %s): nothing was changed.' "$old" "$APP_LOG"
    fi
    accounts_rename_login "$old" "$new" || sftp_rename_undo "$old" "$new" 0 0
    if accounts_group_exists "$old"; then
        accounts_rename_group "$old" "$new" || sftp_rename_undo "$old" "$new" 1 0
        group=1
    fi
    if [[ -e $key_dir/$old ]]; then
        mv -f "$key_dir/$old" "$key_dir/$new" || sftp_rename_undo "$old" "$new" 1 "$group"
    fi
    # in the log (a restore, new credentials): the report hides both names
    log_title 'SFTP account %s renamed to %s' "$old" "$new"
    ok 'Account %s renamed to %s' "$old" "$new"
}

# sftp_rename_undo OLD NEW USER_RENAMED GROUP_RENAMED — a step of the
# rename failed: the old names come back, then stop
sftp_rename_undo() {
    local old=$1 new=$2
    if (($4)) && ! accounts_rename_group "$new" "$old"; then
        # the account stays suspended: half renamed, it must not be used
        if (($3)); then accounts_rename_login "$new" "$old" || true; fi
        die 'Renaming %s to %s failed, and so did putting the old name of the group back (details in %s). The account stays suspended. By hand:  groupmod --new-name %s %s ; usermod --login %s %s ; seedtunnel apply' "$old" "$new" "$APP_LOG" "$old" "$new" "$old" "$new"
    fi
    if (($3)) && ! accounts_rename_login "$new" "$old"; then
        die 'Renaming %s to %s failed, and so did putting the old name back (details in %s). By hand:  usermod --login %s %s' "$old" "$new" "$APP_LOG" "$old" "$new"
    fi
    accounts_resume "$old" || true
    die 'Renaming %s to %s failed (details in %s): the account keeps its name %s.' "$old" "$new" "$APP_LOG" "$old"
}

sftp_generate_conf() {
    local user=$1 data_dir=$2 password=$3 key_dir=$4
    cat <<EOF
# Written by seedtunnel — SFTP access to the seedbox, locked in $data_dir
Match User $user
    ChrootDirectory $data_dir
    ForceCommand internal-sftp -u 0002
    AuthorizedKeysFile $key_dir/%u
    PasswordAuthentication $password
    KbdInteractiveAuthentication no
    PermitTTY no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
}

sftp_apply() {
    local user=$1 data_dir=$2 key_dir=$4 conf=$5
    local -n _sftp_password=$3
    shift 5
    local settings
    install -d -m 755 "$key_dir"
    if [[ ! -e $key_dir/$user ]]; then install -m 644 /dev/null "$key_dir/$user"; fi
    if [[ $_sftp_password == no ]] && ! sftp_account_has_keys "$user" "$key_dir"; then
        warn 'No SSH key saved: the SFTP password stays allowed.'
        _sftp_password=yes
    fi
    if [[ -e $conf ]]; then cp -p "$conf" "$conf.previous"; fi
    if write_if_changed "$conf" 644 root:root sftp_generate_conf "$user" "$data_dir" "$_sftp_password" "$key_dir"; then pending_set ssh; fi
    if pending ssh; then
        # SSH is only reloaded if the configuration is valid: no risk of being
        # locked out. Otherwise, back to the previous version.
        sshd_runtime_dir
        if ! sshd -t >>"$APP_LOG" 2>&1; then
            if [[ -e $conf.previous ]]; then
                mv -f "$conf.previous" "$conf"
                # put back by seedtunnel, not changed by hand
                written_remember "$conf"
            else
                rm -f "$conf"
            fi
            pending_clear ssh
            die 'sshd refuses the generated configuration (details in %s). SSH was not changed.' "$APP_LOG"
        fi
        run 'Reloading SSH' systemctl try-reload-or-restart ssh.service
        pending_clear ssh
    fi
    rm -f "$conf.previous"

    # Do the restrictions really apply to the account (Include present, no
    # Match block before ours…)? If not, the account is suspended: no access
    # at all rather than an account without its restrictions.
    if sftp_rule_applies "$user" "$data_dir" "$_sftp_password" "$key_dir" "$@"; then
        accounts_resume "$user" || die 'The account %s could not be reactivated (details in %s): it stays suspended. By hand:  usermod --expiredate "" %s' "$user" "$APP_LOG" "$user"
    elif accounts_suspend "$user"; then
        die 'The SFTP restrictions (chroot, SFTP only, no tunnel) do not apply to %s: the account is suspended. /etc/ssh/sshd_config must contain "Include /etc/ssh/sshd_config.d/*.conf" before any Match block; then run:  seedtunnel apply' "$user"
    else
        die 'The SFTP restrictions (chroot, SFTP only, no tunnel) do not apply to %s, and the account could not be suspended (details in %s). Suspend it by hand:  usermod --expiredate 1 %s && pkill -KILL -u %s' "$user" "$APP_LOG" "$user" "$user"
    fi
    settings=$(sftp_effective_settings "$user" 127.0.0.1)
    if [[ $settings == *$'\nallowusers '* || $settings == *$'\nallowgroups '* ]]; then
        warn 'Your SSH uses AllowUsers/AllowGroups: add %s to it so that it can connect.' "$user"
    fi
}

# Account key files; names and paths are supplied by the caller.

# A key made by seedtunnel (sftp_key_generate) among those of the account: its
# private part is then the file seedbox-USER.ppk on the computer of the user
sftp_account_has_generated_key() {
    local user=$1 key_dir=$2
    [[ -s $key_dir/$user ]] && grep -q " seedtunnel-$user-[0-9]" "$key_dir/$user"
}

# sftp_account_keys_write USER KEY_DIR CONTENT [KEY…] — the file of the keys becomes CONTENT, plus
# the KEYs, replaced in one go: written next to it (same disk), readable by
# sshd (644), then renamed. If writing fails, the file stays as it was.
sftp_account_keys_write() {
    local file="$2/$1" key_dir=$2 content=$3 tmp
    shift 3
    tmp=$(mktemp "$key_dir/.keys.XXXXXX") || return 1
    if ! {
        if [[ -n $content ]]; then printf '%s\n' "$content"; fi
        if (($#)); then printf '%s\n' "$@"; fi
    } >"$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}

# Number of SSH keys saved for the SFTP account
sftp_account_keys_count() {
    local user=$1 key_dir=$2
    local count=0 line
    [[ -s $key_dir/$user ]] || {
        echo 0
        return 0
    }
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] || count=$((count + 1))
    done <"$key_dir/$user"
    echo "$count"
}

# Adds the valid public keys of a file (- = standard input), without duplicates:
# OpenSSH lines, or the blocks saved by PuTTYgen (ssh_keys_openssh). The keys
# are all checked first, then added in one go: one invalid key, and none is
# added.
sftp_account_keys_import() {
    local user=$1 key_dir=$2 source=$3 line given lines saved status=0 count=0 file="$2/$1"
    local -n _sftp_added=$4
    local -a imported_keys=()
    install -d -m 755 "$key_dir"
    if [[ ! -e $file ]]; then install -m 644 /dev/null "$file"; fi
    if [[ $source == - ]]; then
        given=$(cat)
    elif ! given=$(cat -- "$source" 2>/dev/null); then
        die 'File not found: %s' "$source"
    fi
    lines=$(ssh_keys_openssh <<<"$given") || status=$?
    saved=$(<"$file")
    case $status in
        0) ;;
        3) die 'This is a private key: it stays on your computer. Give the public key (.pub file).' ;;
        *) die 'This block of PuTTYgen cannot be read: copy the line of the frame at the top of PuTTYgen instead.' ;;
    esac
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        if ! ssh-keygen -l -f - <<<"$line" &>/dev/null; then
            die 'Invalid SSH key: %s…' "${line:0:40}"
        fi
        if ! ssh_key_known "$saved" "$line" "${imported_keys[@]}"; then imported_keys+=("$line"); fi
    done <<<"$lines"
    count=${#imported_keys[@]}
    if ((count)); then
        sftp_account_keys_write "$user" "$key_dir" "$(cat -- "$file")" "${imported_keys[@]}" || die 'Cannot write %s (disk full?).' "$file"
    fi
    _sftp_added=$count
}

sftp_account_keys_remove() {
    local user=$1 key_dir=$2 number=$3 file="$2/$1" index=0 line tmp found=0
    [[ $number =~ ^[0-9]{1,9}$ ]] || die 'Give the number of the key (seedtunnel seedbox sftp-key list).'
    number=$((10#$number))
    tmp=$(mktemp)
    while IFS= read -r line; do
        if [[ -n $line && $line != \#* ]]; then
            index=$((index + 1))
            if ((index == number)); then
                found=1
                continue
            fi
        fi
        printf '%s\n' "$line" >>"$tmp"
    done <"$file"
    if ((!found)); then
        rm -f "$tmp"
        die 'Key number %s not found.' "$number"
    fi
    if ! sftp_account_keys_write "$user" "$key_dir" "$(cat -- "$tmp")"; then
        rm -f "$tmp"
        die 'Cannot write %s (disk full?).' "$file"
    fi
    rm -f "$tmp"
}
