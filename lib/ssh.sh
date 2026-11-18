#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — SSH access: keys of the administrators, passwords, root
#  Loaded by seedtunnel.sh: this file does nothing on its own.
#
#  What sshd really does for each account is read from « sshd -T -C » (its
#  settings for a connection of that account from the Internet), never from
#  the files. Root never logs in by SSH: the administrators log in with their
#  own account, then sudo -i. seedtunnel changes one file only, read before
#  the others of /etc/ssh/sshd_config.d (sshd keeps the first value it reads):
#  root refused, and on request the passwords too (keys only). Each change is
#  tried for 2 minutes, and kept only once a NEW connection of the account
#  running seedtunnel went through; otherwise it undoes itself. seedtunnel
#  apply writes the file again if it was changed or removed.
#  The keys are added to the files sshd reads for the account
#  (AuthorizedKeysFile), written by the account itself.
#  Not in the backups: on a new server, the accounts and the keys are not
#  the same, and refusing root there could close the server.
# =============================================================================

SSH_MAIN_CONF="/etc/ssh/sshd_config"
# Before 50-cloud-init.conf and seedtunnel-seedbox.conf (its Match block for
# the SFTP account keeps its own setting for the password)
SSH_ADMIN_CONF="/etc/ssh/sshd_config.d/00-seedtunnel-admin.conf"
# What seedtunnel keeps: « root » (root refused) or « keys » (passwords
# refused too). Beside the settings of sshd, never in /etc/seedtunnel: never
# in a backup.
SSH_ACCESS_STATE="/etc/ssh/seedtunnel_access"
SSH_ROLLBACK_UNIT="seedtunnel-ssh-rollback"
# a connection from the Internet, as sshd sees it (an address kept for
# documentation: no Match block of the administrator is written for it)
SSH_INTERNET_ADDRESS="203.0.113.1"

# --- Accounts -----------------------------------------------------------------------

# The accounts that administer the server: the one running seedtunnel
# through sudo first, then the members of the group sudo that can log in.
# Never root (said apart), never the SFTP account. One per line.
ssh_admin_accounts() {
    local user shell
    local -A seen=()
    {
        if [[ -n ${SUDO_USER-} && $SUDO_USER != root ]]; then printf '%s\n' "$SUDO_USER"; fi
        getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' '\n'
    } | while IFS= read -r user; do
        [[ -n $user && -z ${seen[$user]-} && $user != root && $user != "${SEEDBOX_USER-}" ]] || continue
        seen[$user]=1
        shell=$(getent passwd "$user" 2>/dev/null | cut -d: -f7) || continue
        [[ -n $shell && $shell != */nologin && $shell != */false ]] || continue
        printf '%s\n' "$user"
    done
}

# ssh_home USER — its personal folder
ssh_home() { getent passwd "$1" 2>/dev/null | cut -d: -f6; }

# ssh_password_set USER — the account has a password that can be used (not
# locked, not empty: « passwd -S » says P)
ssh_password_set() {
    local status
    status=$(passwd -S "$1" 2>/dev/null | awk '{ print $2 }') || return 1
    [[ $status == P ]]
}

# The account at the keyboard: the one that ran sudo seedtunnel (never
# root). Refusing root, or the passwords, is proved by a new connection of
# that account: run by root itself, nothing can prove it.
ssh_own_account_refuse() {
    if [[ -z ${SUDO_USER-} || $SUDO_USER == root ]]; then
        refuse "$(t 'Your account first')" \
            "$(t 'Root never logs in by SSH: log in with your own account (not root), then run sudo seedtunnel. Nothing was changed.')" \
            "$(t 'No account but root? Create one that can use sudo, log in with it, then come back here.')"
    fi
}

# --- What sshd does -------------------------------------------------------------------

# ssh_settings USER — the settings of sshd for a connection of USER from the
# Internet
ssh_settings() { sshd_settings -C "user=$1,host=$SSH_INTERNET_ADDRESS,addr=$SSH_INTERNET_ADDRESS"; }

# ssh_setting NAME < SETTINGS — its value (the first one)
ssh_setting() { awk -v name="$1" '$1 == name { $1 = ""; sub(/^ /, ""); print; exit }'; }

# ssh_password_allowed SETTINGS — sshd accepts a password (directly, or through
# PAM with keyboard-interactive)
ssh_password_allowed() {
    [[ $(ssh_setting passwordauthentication <<<"$1") == yes ]] && return 0
    [[ $(ssh_setting kbdinteractiveauthentication <<<"$1") == yes && $(ssh_setting usepam <<<"$1") == yes ]]
}

# ssh_keys_by_command SETTINGS — the keys come from a program (AuthorizedKeysCommand):
# seedtunnel does not touch anything then
ssh_keys_by_command() {
    local command
    command=$(ssh_setting authorizedkeyscommand <<<"$1")
    [[ -n $command && $command != none ]]
}

# ssh_key_files USER SETTINGS — the files of keys sshd reads for USER, one
# per line (« %h », « %u », « %U » and « %% » replaced; a relative path is
# in its personal folder)
ssh_key_files() {
    local user=$1 home uid file
    local -a files=()
    home=$(ssh_home "$user")
    uid=$(id -u "$user" 2>/dev/null) || uid=""
    read -ra files <<<"$(ssh_setting authorizedkeysfile <<<"$2")"
    for file in "${files[@]}"; do
        [[ $file != none ]] || continue
        file=${file//%%/$'\x01'}
        file=${file//%h/$home}
        file=${file//%u/$user}
        file=${file//%U/$uid}
        file=${file//$'\x01'/%}
        if [[ $file != /* ]]; then file="$home/$file"; fi
        printf '%s\n' "$file"
    done
}

# ssh_key_file USER SETTINGS — the first file of keys sshd reads for USER,
# where seedtunnel adds a key (the list taken whole: « | head » under
# pipefail can stop it with SIGPIPE)
ssh_key_file() {
    local files
    files=$(ssh_key_files "$1" "$2")
    printf '%s\n' "${files%%$'\n'*}"
}

# ssh_keys_count USER SETTINGS — how many keys sshd would accept for USER
ssh_keys_count() {
    local file count=0 lines
    while IFS= read -r file; do
        [[ -f $file ]] || continue
        lines=$(ssh-keygen -l -f "$file" 2>/dev/null | grep -c . || true)
        count=$((count + ${lines:-0}))
    done < <(ssh_key_files "$1" "$2")
    printf '%s' "$count"
}

# ssh_account_state USER — how many keys, whether a password gets in (sshd
# accepts it, and the account has one), whether a program gives the keys;
# for root, what sshd says of it (PermitRootLogin)
SSH_STATE_KEYS=0
SSH_STATE_PASSWORD=0
SSH_STATE_COMMAND=0
SSH_STATE_ROOT=""
ssh_account_state() {
    local settings
    settings=$(ssh_settings "$1")
    SSH_STATE_COMMAND=0
    SSH_STATE_PASSWORD=0
    if ssh_keys_by_command "$settings"; then SSH_STATE_COMMAND=1; fi
    SSH_STATE_KEYS=$(ssh_keys_count "$1" "$settings")
    SSH_STATE_ROOT=$(ssh_setting permitrootlogin <<<"$settings")
    if ssh_password_allowed "$settings" && ssh_password_set "$1"; then
        # root: only if sshd lets it in with a password
        if [[ $1 != root || $SSH_STATE_ROOT == yes ]]; then SSH_STATE_PASSWORD=1; fi
    fi
}

# Root refused in SSH, as sshd really does it
ssh_root_refused() { [[ $(ssh_setting permitrootlogin <<<"$(ssh_settings root)") == no ]]; }

# --- Public keys ----------------------------------------------------------------------

# ssh_ask_public_key VARIABLE — the public key pasted in the menu (one
# OpenSSH line, or the block of PuTTYgen). Status 1: back.
ssh_ask_public_key() {
    local _ssh_var=$1 _ssh_key _ssh_rest _ssh_status
    while true; do
        ask_back _ssh_key 'Public key' "" || return 1
        if [[ $_ssh_key == "---- BEGIN SSH2 PUBLIC KEY ----" ]]; then
            _ssh_status=0
            _ssh_key=$(ssh_pasted_block "$_ssh_key") || _ssh_status=$?
            if ((_ssh_status == 0)) && ssh-keygen -l -f - <<<"$_ssh_key" &>/dev/null; then break; fi
            warn 'This block of PuTTYgen cannot be read: copy the line of the frame at the top of PuTTYgen instead.'
            continue
        fi
        if ssh-keygen -l -f - <<<"$_ssh_key" &>/dev/null; then break; fi
        if [[ $_ssh_key == *"PRIVATE KEY"* || $_ssh_key == PuTTY-User-Key-File* ]]; then
            # the other lines of the pasted private key, not read as answers
            while IFS= read -r -t 1 _ssh_rest; do :; done
            warn 'This is a private key: it stays on your computer. Paste the public key (.pub file).'
            continue
        fi
        warn 'Invalid SSH key: %s…' "${_ssh_key:0:40}"
    done
    printf -v "$_ssh_var" '%s' "$_ssh_key"
}

# ssh_as USER COMMAND… — COMMAND run by USER (root: as it is): what is
# written in the folder of an account is written by the account itself, never
# by root through a link it put there
ssh_as() {
    local user=$1
    shift
    if [[ $user == root ]]; then
        "$@"
    else
        runuser -u "$user" -- "$@"
    fi
}

# ssh_keys_import USER SOURCE — the valid public keys of SOURCE (a file, - =
# standard input) added for USER, without duplicates, in the first file of
# keys sshd reads for it. All are checked first: one invalid key, none added.
ssh_keys_import() {
    local user=$1 source=$2 given keys status=0 settings file line saved count=0
    local -a new=()
    getent passwd "$user" >/dev/null || die 'Account not found: %s' "$user"
    [[ $user != root ]] || die 'Root never logs in by SSH: add the key to your own account.'
    if [[ $source == - ]]; then
        given=$(cat)
    elif ! given=$(cat -- "$source" 2>/dev/null); then
        die 'File not found: %s' "$source"
    fi
    keys=$(ssh_keys_openssh <<<"$given") || status=$?
    case $status in
        0) ;;
        3) die 'This is a private key: it stays on your computer. Give the public key (.pub file).' ;;
        *) die 'This block of PuTTYgen cannot be read: copy the line of the frame at the top of PuTTYgen instead.' ;;
    esac
    [[ -n $keys ]] || die 'No SSH key in %s.' "$source"
    settings=$(ssh_settings "$user")
    if ssh_keys_by_command "$settings"; then
        die 'The SSH keys of %s are given by a program (AuthorizedKeysCommand): seedtunnel does not touch them.' "$user"
    fi
    file=$(ssh_key_file "$user" "$settings")
    [[ -n $file ]] || die 'sshd reads no file of keys for %s (AuthorizedKeysFile none).' "$user"
    # read by the account itself, as it writes it
    saved=$(ssh_as "$user" cat -- "$file" 2>/dev/null || true)
    while IFS= read -r line; do
        ssh-keygen -l -f - <<<"$line" &>/dev/null || die 'Invalid SSH key: %s…' "${line:0:40}"
        if ! ssh_key_known "$saved" "$line" "${new[@]}"; then new+=("$line"); fi
    done <<<"$keys"
    count=${#new[@]}
    if ((count == 0)); then
        ok 'Key(s) already saved for %s.' "$user"
        return 0
    fi
    # written by the account itself, folder and file closed to the others
    if ! printf '%s\n' "${new[@]}" | ssh_as "$user" sh -c 'umask 077 && mkdir -p "$(dirname "$1")" && cat >>"$1" && chmod 600 "$1"' sh "$file" 2>>"$APP_LOG"; then
        die 'Cannot write %s (details in %s).' "$file" "$APP_LOG"
    fi
    log_title 'SSH key(s) added for %s: %s' "$user" "$count"
    ok '%s SSH key(s) added for %s (%s).' "$count" "$user" "$file"
}

# ssh_key_new USER — a key made on the server: its public part added for USER,
# its private part sent once as a .ppk file (PuTTY), through a one-time link.
# No copy stays on the server.
ssh_key_new() {
    local user=$1 comment name
    getent passwd "$user" >/dev/null || die 'Account not found: %s' "$user"
    [[ $user != root ]] || die 'Root never logs in by SSH: add the key to your own account.'
    share_require "$(t 'Without a link: make the key on your computer (PuTTYgen, or ssh-keygen -t ed25519), then add its public part:  seedtunnel ssh key add FILE.pub %s' "$user")"
    ((SHARE_READY)) || return 0
    apt_install putty-tools
    comment="seedtunnel-$user-$(date +%Y%m%d-%H%M%S)"
    name="ssh-$user.ppk"
    # in a subshell of its own: the temporary folder with the private key is
    # deleted whatever happens, even if a step stops the script
    in_subshell ssh_key_create_and_share "$user" "$comment" "$name"
    say 'In PuTTY: Connection › SSH › Auth › Credentials › « Private key file »: this file, then save the session.'
    say 'Link unused? The key "%s" stays allowed: remove it (menu Access and keys › SSH accounts and keys), then create another one.' "$comment"
}

# --- The keys of an account: see, remove ----------------------------------------------

# ssh_key_entries USER — the keys sshd reads for USER, one per line:
# « FILE<TAB>LINE », read by the account itself (comments and empty lines
# left out)
ssh_key_entries() {
    local user=$1 file line
    while IFS= read -r file; do
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ -n ${line// /} && $line != \#* ]] || continue
            printf '%s\t%s\n' "$file" "$line"
        done < <(ssh_as "$user" cat -- "$file" 2>/dev/null || true)
    done < <(ssh_key_files "$user" "$(ssh_settings "$user")")
}

# ssh_keys_show USER — its keys, numbered: type and name (the comment), then
# the start of the fingerprint, and the file when it is not the usual one
# (the personal folder written ~)
ssh_keys_show() {
    local user=$1 file line words fingerprint type name home first i=0
    home=$(ssh_home "$user")
    first=$(ssh_key_file "$user" "$(ssh_settings "$user")")
    while IFS=$'\t' read -r file line; do
        i=$((i + 1))
        # « 256 SHA256:… comment (ED25519) »
        words=$(ssh-keygen -l -f - <<<"$line" 2>/dev/null) || words=""
        if [[ $words =~ ^[0-9]+\ ([^ ]+)\ ?(.*)\ \(([^\)]+)\)$ ]]; then
            fingerprint=${BASH_REMATCH[1]}
            name=${BASH_REMATCH[2]}
            type=${BASH_REMATCH[3]}
        else
            fingerprint="" type="?" name="$(t '(not a valid key)')"
        fi
        [[ -n $name && $name != "no comment" ]] || name=$(t '(no name)')
        # the file, when it is not the usual one
        if [[ $file == "$first" ]]; then
            file=""
        elif [[ -n $home && $file == "$home"/* ]]; then
            file="~${file#"$home"}"
        fi
        if ((INTERACTIVE)); then
            ui_paragraph "$C_BRAND$i$C_RESET  $type · $name"
            ui_paragraph "$C_GREY$fingerprint$C_RESET"
            if [[ -n $file ]]; then ui_paragraph "$file"; fi
        else
            if ((${#fingerprint} > 23)); then fingerprint="${fingerprint:0:22}…"; fi
            printf '  %s%2s%s  %s · %s\n' "$C_BRAND" "$i" "$C_RESET" "$type" "$name"
            printf '      %s%s%s%s\n' "$C_GREY" "$fingerprint" "${file:+  $file}" "$C_RESET"
        fi
    done < <(ssh_key_entries "$user")
    if ((i == 0)); then printf '  %s\n' "$(t 'No SSH key for %s.' "$user")"; fi
}

# ssh_key_remove USER NUMBER — the key NUMBER of the list removed from its
# file, by the account itself. Never the last key of the account running
# seedtunnel while the passwords are refused (it could no longer log in).
ssh_key_remove() {
    local user=$1 number=$2 count file line
    local -a entries=()
    mapfile -t entries < <(ssh_key_entries "$user")
    count=${#entries[@]}
    if [[ ! $number =~ ^[0-9]{1,4}$ ]] || ((10#$number < 1 || 10#$number > count)); then
        die 'No key number %s for %s (seedtunnel ssh key list %s).' "$number" "$user" "$user"
    fi
    if ((count == 1)) && [[ $user == "${SUDO_USER-}" && $(ssh_access_mode) == keys ]]; then
        refuse "$(t 'Last key of %s' "$user")" \
            "$(t 'The passwords are refused: without this key, %s could no longer log in. Nothing was changed.' "$user")" \
            "$(t 'To go on: add another key first, or accept the passwords again.')"
    fi
    file=${entries[10#$number - 1]%%$'\t'*}
    line=${entries[10#$number - 1]#*$'\t'}
    # every line identical to it goes; the file keeps its rights
    if ! ssh_as "$user" sh -c 'umask 077 && { grep -vxF -- "$2" "$1" >"$1.seedtunnel-new"; [ $? -le 1 ]; } && cat "$1.seedtunnel-new" >"$1"; status=$?; rm -f "$1.seedtunnel-new"; exit $status' \
        sh "$file" "$line" 2>>"$APP_LOG"; then
        die 'Cannot write %s (details in %s).' "$file" "$APP_LOG"
    fi
    log_title 'SSH key removed for %s: %s' "$user" "$(ssh_key_data "$line" | cut -c1-24)"
    ok 'Key %s of %s removed.' "$number" "$user"
}

# ssh_key_create_and_share USER COMMENT NAME — in a subshell (in_subshell):
# its trap deletes the private key when the subshell ends
ssh_key_create_and_share() {
    local user=$1 comment=$2 name=$3
    SSH_KEY_TMP=$(mktemp -d)
    trap 'rm -rf "$SSH_KEY_TMP"' EXIT
    if ! ssh_key_pair_create "$SSH_KEY_TMP" "$comment"; then
        die 'Cannot create the SSH key (details in %s).' "$APP_LOG"
    fi
    ssh_keys_import "$user" "$SSH_KEY_TMP/key.pub"
    share_create "$SSH_KEY_TMP/key.ppk" "$name" "$(t 'SSH key of %s for PuTTY' "$user")" \
        "$(text share_steps_ssh_key)" "$(t 'This key opens the server as %s: keep it to yourself.' "$user")"
}

# --- What seedtunnel keeps: root refused, keys only ------------------------------------

# ssh_access_mode — « keys » (passwords and root refused), « root » (root
# refused), or nothing. Its state, or else what its file says (a state
# removed by hand, or a file written before the state existed).
ssh_access_mode() {
    local SSH_ACCESS=""
    state_read "$SSH_ACCESS_STATE" seedtunnel_access
    if [[ -z $SSH_ACCESS && -f $SSH_ADMIN_CONF ]]; then
        if grep -qix 'PasswordAuthentication no' "$SSH_ADMIN_CONF"; then SSH_ACCESS=keys; else SSH_ACCESS=root; fi
    fi
    case $SSH_ACCESS in
        keys | root) printf '%s' "$SSH_ACCESS" ;;
    esac
}

# ssh_access_save MODE
ssh_access_save() {
    local SSH_ACCESS=$1
    state_write "$SSH_ACCESS_STATE" SSH_ACCESS
}

# ssh_generate_admin_conf MODE — the file read before the others: root never
# logs in by SSH; « keys »: the passwords refused too, for every account (the
# SFTP account keeps its own setting: its Match block)
ssh_generate_admin_conf() {
    printf '%s\n' "# Written by seedtunnel (SSH access), written again by « seedtunnel apply »." \
        "# Root never logs in by SSH: log in with your own account, then sudo -i." \
        "PermitRootLogin no"
    if [[ $1 == keys ]]; then
        printf '%s\n' "# Keys only. To accept the passwords again:  seedtunnel ssh password on" \
            "PasswordAuthentication no" \
            "KbdInteractiveAuthentication no"
    fi
}

# The SSH service reads its settings again (the connections open stay open).
# Ubuntu: with ssh.socket, a service not running yet reads them when it starts.
ssh_reload() { run 'Reloading SSH' systemctl try-reload-or-restart ssh.service; }

# ssh_admin_conf_put MODE — the file written, checked by sshd. Status 1 if
# sshd refuses it (the previous file is put back).
ssh_admin_conf_put() {
    if [[ -e $SSH_ADMIN_CONF ]]; then cp -p "$SSH_ADMIN_CONF" "$SSH_ADMIN_CONF.previous"; fi
    ssh_generate_admin_conf "$1" >"$SSH_ADMIN_CONF.new" && chmod 644 "$SSH_ADMIN_CONF.new" \
        && mv -f "$SSH_ADMIN_CONF.new" "$SSH_ADMIN_CONF" || die 'Cannot write %s (disk full?).' "$SSH_ADMIN_CONF"
    sshd_runtime_dir
    if ! sshd -t >>"$APP_LOG" 2>&1; then
        ssh_admin_conf_back "$1"
        return 1
    fi
}

# ssh_admin_conf_back MODE — the file as it was before the last
# ssh_admin_conf_put MODE (or none). Removed only while it is still the one
# written: the automatic undo may have put the previous one back already.
ssh_admin_conf_back() {
    if [[ -e $SSH_ADMIN_CONF.previous ]]; then
        mv -f "$SSH_ADMIN_CONF.previous" "$SSH_ADMIN_CONF"
    elif [[ -f $SSH_ADMIN_CONF ]] && cmp -s <(ssh_generate_admin_conf "$1") "$SSH_ADMIN_CONF"; then
        rm -f "$SSH_ADMIN_CONF"
    fi
}

# The command of the automatic undo: the file as it was, SSH reloaded
ssh_undo_command() {
    if [[ -e $SSH_ADMIN_CONF.previous ]]; then
        printf 'mv -f %q %q; systemctl try-reload-or-restart ssh.service' "$SSH_ADMIN_CONF.previous" "$SSH_ADMIN_CONF"
    else
        printf 'rm -f %q; systemctl try-reload-or-restart ssh.service' "$SSH_ADMIN_CONF"
    fi
}

# ssh_admin_conf_ignored MODE — once the file is in place, what sshd would
# still do otherwise, one line each: « root PermitRootLogin », « ACCOUNT
# PasswordAuthentication » (a setting read before it, or a Match block)
ssh_admin_conf_ignored() {
    local user
    if ! ssh_root_refused; then printf '%s\n' "root PermitRootLogin"; fi
    [[ $1 == keys ]] || return 0
    while IFS= read -r user; do
        if ssh_password_allowed "$(ssh_settings "$user")"; then printf '%s\n' "$user PasswordAuthentication"; fi
    done < <(ssh_admin_accounts)
}

# ssh_ignored_words LINES — what sshd would still do, and where it is set
# (ssh_setting_where), on one line
ssh_ignored_words() {
    local who setting words=""
    while read -r who setting; do
        [[ -n $who ]] || continue
        words+="${words:+; }$who: $setting $(ssh_setting_where "$setting")"
    done <<<"$1"
    printf '%s' "$words"
}

# seedtunnel apply: the file written again when it was changed or removed
# (a state found in the file only is kept as the state)
ssh_access_apply() {
    local mode
    mode=$(ssh_access_mode)
    [[ -n $mode ]] || return 0
    ssh_access_save "$mode"
    if [[ -f $SSH_ADMIN_CONF && ! -L $SSH_ADMIN_CONF ]] && cmp -s <(ssh_generate_admin_conf "$mode") "$SSH_ADMIN_CONF"; then
        return 0
    fi
    if ! ssh_admin_conf_put "$mode"; then
        warn 'sshd refuses the setting of seedtunnel for SSH (details in %s): root may log in again   → seedtunnel doctor' "$APP_LOG"
        return 0
    fi
    rm -f "$SSH_ADMIN_CONF.previous"
    ssh_reload
    log_title 'SSH: setting of seedtunnel written again (%s)' "$mode"
}

# --- The settings of sshd, where they come from ------------------------------------------

# ssh_config_lines — the settings of sshd in the order it reads them, Include
# followed: « FILE<TAB>NUMBER<TAB>IN_MATCH<TAB>LINE », and a line
# « FILE<TAB>0<TAB>0<TAB> » when a file starts (comments left out)
ssh_config_lines() { ssh_config_file_lines "$SSH_MAIN_CONF" 0; }

ssh_config_file_lines() {
    local file=$1 depth=$2 number=0 in_match=0 line word rest pattern included
    ((depth < 5)) || return 0
    [[ -f $file && -r $file ]] || return 0
    printf '%s\t0\t0\t\n' "$file"
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        [[ -n $line && $line != \#* ]] || continue
        word=${line%%[[:space:]=]*}
        case ${word,,} in
            include)
                rest=${line:${#word}}
                rest=${rest#*[[:space:]=]}
                # the patterns, as sshd expands them (sorted), relative to /etc/ssh
                for pattern in $rest; do
                    [[ $pattern == /* ]] || pattern="${SSH_MAIN_CONF%/*}/$pattern"
                    for included in $pattern; do ssh_config_file_lines "$included" $((depth + 1)); done
                done
                continue
                ;;
            match) in_match=1 ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$file" "$number" "$in_match" "$line"
    done <"$file"
}

# ssh_setting_where NAME — « (FILE:NUMBER) » where sshd takes the value of
# NAME for everyone (the first one read, outside the Match blocks),
# « (default of OpenSSH) » otherwise
ssh_setting_where() {
    local name=${1,,} file number in_match line word
    while IFS=$'\t' read -r file number in_match line; do
        ((number > 0 && !in_match)) || continue
        word=${line%%[[:space:]=]*}
        if [[ ${word,,} == "$name" ]]; then
            printf '(%s:%s)' "$file" "$number"
            return 0
        fi
    done < <(ssh_config_lines)
    printf '(%s)' "$(t 'default of OpenSSH')"
}

# The screen « SSH rules in force »: the files sshd reads, then what it does
# for everyone and where it is set (the file and the line), then the result
# for each administrator, and root (PermitRootLogin, its own)
ssh_rules_show() {
    local file number in_match line user settings value i=0
    while IFS=$'\t' read -r file number in_match line; do
        if ((number == 0)); then
            i=$((i + 1))
            ui_field_add "$i" "$file"
        fi
    done < <(ssh_config_lines)
    ui_group "$(t 'Files read by sshd, in this order')"
    echo
    settings=$(ssh_settings root)
    ui_field_add "$(t 'Port')" "$(ssh_setting_all port <<<"$settings")"
    if ssh_password_allowed "$settings"; then value=$(t 'accepted'); else value=$(t 'refused'); fi
    ui_field_add "$(t 'Password')" "$value $(ssh_setting_where PasswordAuthentication)"
    ui_field_add "$(t 'Keys accepted')" "$(ssh_yes_no "$(ssh_setting pubkeyauthentication <<<"$settings")") $(ssh_setting_where PubkeyAuthentication)"
    ui_field_add "$(t 'Tries per connection')" "$(ssh_setting maxauthtries <<<"$settings")"
    ui_group "$(t 'For every account')"
    # the result for each administrator (a Match block can make it differ)
    while IFS= read -r user; do
        echo
        settings=$(ssh_settings "$user")
        if ssh_password_allowed "$settings"; then value=$(t 'accepted'); else value=$(t 'refused'); fi
        ui_field_add "$(t 'Password')" "$value"
        ui_field_add "$(t 'Keys')" "$(ssh_keys_count "$user" "$settings")"
        ui_group "$user"
    done < <(ssh_admin_accounts)
    echo
    settings=$(ssh_settings root)
    value=$(ssh_setting permitrootlogin <<<"$settings")
    if [[ $value == no ]]; then
        value="$C_GREEN$(t 'refused')$C_RESET"
    else
        value="$C_RED$(t 'not refused (%s)' "$value")$C_RESET"
    fi
    ui_field_add SSH "$value $(ssh_setting_where PermitRootLogin)"
    ui_field_add "$(t 'Keys')" "$(ssh_keys_count root "$settings")"
    ui_group root
}

# ssh_setting_all NAME < SETTINGS — all its values (Port can be given more than
# once), separated by commas
ssh_setting_all() { awk -v name="$1" '$1 == name { printf "%s%s", (n++ ? ", " : ""), $2 }'; }

# ssh_yes_no VALUE — yes or no, in words
ssh_yes_no() { if [[ $1 == yes ]]; then t 'yes'; else t 'no'; fi; }

ssh_rules_menu() {
    banner
    section 'SSH rules in force'
    ssh_rules_show
    echo
    pause
}

# --- The trial: root refused, or keys only ------------------------------------------------

# SSH logins accepted since $1 (seconds since 1970), one per line: « METHOD
# ADDRESS USER » (publickey, password, keyboard-interactive/pam). Only the
# messages written by the OpenSSH programs (see firewall_ssh_logins).
ssh_logins() {
    local program
    local -a filters=()
    for program in $FIREWALL_SSHD_PROGRAMS; do filters+=("_EXE=$program"); done
    journalctl --since "@$1" -o cat --no-pager "${filters[@]}" 2>/dev/null \
        | sed -nE 's/^Accepted ([^ ]+) for ([^ ]+) from ([^ ]+) port .*/\1 \3 \2/p' || true
}

# ssh_new_login START USER METHOD — a NEW connection of USER since START, not
# from the server itself; METHOD: publickey, or any
ssh_new_login() {
    local method address user
    while read -r method address user; do
        [[ -n $address && $user == "$2" ]] || continue
        [[ $3 == any || $method == "$3" ]] || continue
        if network_is_local_address "$address"; then continue; fi
        return 0
    done < <(ssh_logins "$1")
    return 1
}

# ssh_trial_text MODE PART — the words of the trial, for root refused or for
# keys only
ssh_trial_text() {
    case "$1 $2" in
        "root title") t 'New SSH connection of %s' "$SUDO_USER" ;;
        "root open") t 'Open a NEW SSH connection to this server as %s (another PuTTY window, for example), without closing this one: it proves that you can still get in.' "$SUDO_USER" ;;
        "root undo") t 'Without it, root is accepted again in 2 minutes.' ;;
        "root none") t 'No new connection of %s yet' "$SUDO_USER" ;;
        "root again") t 'Open a NEW window (keep this one), log in as %s, then type "yes" again.' "$SUDO_USER" ;;
        "root ask") t 'Does it work? Type "yes" to refuse root:' ;;
        "keys title") t 'New SSH connection with your key' ;;
        "keys open") t 'Open a NEW SSH connection to this server (another PuTTY window, for example) and log in with your key, without closing this one: it proves that your key opens the server.' ;;
        "keys undo") t 'Without it, the passwords are accepted again in 2 minutes.' ;;
        "keys none") t 'No new connection with a key yet' ;;
        "keys again") t 'Open a NEW window (keep this one), log in with your key, then type "yes" again.' ;;
        "keys ask") t 'Does it work? Type "yes" to keep the keys only:' ;;
    esac
}

# ssh_wait_confirmation MODE START — « yes » keeps the change only once a new
# connection of the account running seedtunnel went through (with a key for
# « keys »); any other answer, or no proof before the automatic undo, cancels
ssh_wait_confirmation() {
    local mode=$1 start=$2 method=any answer left
    if [[ $mode == keys ]]; then method=publickey; fi
    while :; do
        left=$((start + 110 - $(date +%s)))
        ((left > 0)) || return 1
        IFS= read -r -t "$left" -p "$(ssh_trial_text "$mode" ask) " answer || return 1
        [[ ${answer,,} == yes || ${answer,,} == oui ]] || return 1
        if ssh_new_login "$start" "$SUDO_USER" "$method"; then return 0; fi
        echo
        ui_box bad "$(ssh_trial_text "$mode" none)" \
            "$(t 'seedtunnel has seen none since the change.')" \
            "$(ssh_trial_text "$mode" again)" \
            "$(t 'Time left: %s.' "$(duration_text "$((start + 110 - $(date +%s)))")")"
        echo
    done
}

# ssh_access_trial MODE — the file of MODE put in place for 2 minutes; kept
# once proved (ssh_wait_confirmation), otherwise everything as before. Status
# 1: cancelled.
ssh_access_trial() {
    local mode=$1 start ignored
    if ! ssh_admin_conf_put "$mode"; then
        die 'sshd refuses the change (details in %s): nothing was changed.' "$APP_LOG"
    fi
    # a setting read before the file of seedtunnel would still win
    ignored=$(ssh_admin_conf_ignored "$mode")
    if [[ -n $ignored ]]; then
        ssh_admin_conf_back "$mode"
        refuse "$(t 'A setting wins over seedtunnel')" \
            "$(t 'sshd would still do otherwise: %s. Nothing was changed.' "$(ssh_ignored_words "$ignored")")" \
            "$(t 'To go on: remove that setting (menu Access and keys › SSH rules in force), then try again.')"
    fi
    systemctl stop "$SSH_ROLLBACK_UNIT.timer" &>/dev/null || true
    systemctl reset-failed "$SSH_ROLLBACK_UNIT.timer" "$SSH_ROLLBACK_UNIT.service" &>/dev/null || true
    run 'Scheduling the automatic undo (2 min)' \
        systemd-run --quiet --unit="$SSH_ROLLBACK_UNIT" --on-active=120 /bin/sh -c "$(ssh_undo_command)"
    ssh_reload
    start=$(date +%s)
    echo
    ui_box info "$(ssh_trial_text "$mode" title)" "$(ssh_trial_text "$mode" open)" "$(ssh_trial_text "$mode" undo)"
    echo
    if ! ssh_wait_confirmation "$mode" "$start"; then
        echo
        ssh_admin_conf_back "$mode"
        ssh_reload
        systemctl stop "$SSH_ROLLBACK_UNIT.timer" &>/dev/null || true
        warn 'Change cancelled: SSH as before.'
        return 1
    fi
    systemctl stop "$SSH_ROLLBACK_UNIT.timer" &>/dev/null || true
    # the automatic undo must really be cancelled before the change is kept
    if systemctl is-active --quiet "$SSH_ROLLBACK_UNIT.timer"; then
        ssh_admin_conf_back "$mode"
        ssh_reload
        die 'The automatic undo could not be cancelled: SSH as before, nothing was kept (details in %s).' "$APP_LOG"
    fi
    rm -f "$SSH_ADMIN_CONF.previous"
    ssh_access_save "$mode"
}

# Root refused in SSH, with a password or a key: the administrators log in
# with their own account, then sudo -i
ssh_root_off() {
    banner
    section 'Refuse root in SSH'
    ssh_own_account_refuse
    if ssh_root_refused; then
        # refused by the settings of the system: kept by seedtunnel from now
        # on (nothing changes for sshd, nothing to try)
        if [[ -z $(ssh_access_mode) ]]; then
            if ! ssh_admin_conf_put root; then
                die 'sshd refuses the change (details in %s): nothing was changed.' "$APP_LOG"
            fi
            rm -f "$SSH_ADMIN_CONF.previous"
            ssh_access_save root
            ssh_reload
            log_title 'SSH: root refused (already refused by the system)'
        fi
        ok 'Root is refused in SSH.'
        pause
        return 0
    fi
    if ((!INTERACTIVE)); then
        die 'This change is tried for 2 minutes, from a terminal:  seedtunnel ssh root off'
    fi
    ui_box good "$(t 'Root refused in SSH')" \
        "$(t 'Root no longer logs in by SSH, with a password or with a key. You log in as %s, then sudo -i.' "$SUDO_USER")" \
        "$(t 'Tried for 2 minutes: kept only once a NEW connection of %s went through; otherwise root is accepted again by itself.' "$SUDO_USER")"
    echo
    if ! confirm 'Refuse root in SSH?' y; then return 0; fi
    if ssh_access_trial root; then
        log_title 'SSH: root refused, proved by a connection of %s' "$SUDO_USER"
        echo
        ok 'Root refused in SSH: log in as %s, then sudo -i.' "$SUDO_USER"
    fi
    pause
}

# Keys only: the passwords refused for every administrator, root refused
ssh_password_off() {
    local settings
    banner
    section 'Refuse the passwords (keys only)'
    ssh_own_account_refuse
    settings=$(ssh_settings "$SUDO_USER")
    if ssh_keys_by_command "$settings"; then
        refuse "$(t 'Keys given by a program')" \
            "$(t 'The SSH keys of %s come from AuthorizedKeysCommand: seedtunnel cannot check them. Nothing was changed.' "$SUDO_USER")" \
            "$(t 'To go on: refuse the passwords in /etc/ssh/sshd_config yourself.')"
    fi
    if (($(ssh_keys_count "$SUDO_USER" "$settings") == 0)); then
        refuse "$(t 'No SSH key for %s' "$SUDO_USER")" \
            "$(t 'Without a key, refusing the passwords would close the server to %s, who runs seedtunnel. Nothing was changed.' "$SUDO_USER")" \
            "$(t 'To go on: add your key first (seedtunnel ssh key add FILE.pub, or the menu Access and keys).')"
    fi
    if ((!INTERACTIVE)); then
        die 'This change is tried for 2 minutes, from a terminal:  seedtunnel ssh password off'
    fi
    ui_box good "$(t 'Keys only')" \
        "$(t 'Passwords refused for every administrator, and root refused in SSH: you log in as %s with your key, then sudo -i.' "$SUDO_USER")" \
        "$(t 'Tried for 2 minutes: kept only once a NEW connection with your key went through; otherwise SSH comes back as before by itself.')"
    echo
    if ! confirm 'Refuse the passwords?' y; then return 0; fi
    if ssh_access_trial keys; then
        log_title 'SSH: passwords refused, proved by a connection of %s with a key' "$SUDO_USER"
        echo
        ok 'Keys only, root refused (proved by %s).' "$SUDO_USER"
    fi
    pause
}

# The passwords accepted again; root stays refused (never given back)
ssh_password_on() {
    banner
    section 'Accept the passwords again'
    if [[ $(ssh_access_mode) != keys ]]; then
        say 'seedtunnel refuses no password: what sshd does comes from its own settings (menu Access and keys › SSH rules in force).'
        pause
        return 0
    fi
    if ! confirm 'Accept the passwords again (root stays refused in SSH)?' n; then return 0; fi
    if ! ssh_admin_conf_put root; then
        die 'sshd refuses the change (details in %s): nothing was changed.' "$APP_LOG"
    fi
    rm -f "$SSH_ADMIN_CONF.previous"
    ssh_access_save root
    ssh_reload
    log_title 'SSH: passwords accepted again, root refused'
    ok 'Passwords accepted again; root stays refused in SSH.'
    pause
}

# --- State, menu and commands ---------------------------------------------------------

# ssh_dot COLOR TEXT — « ● TEXT », the dot in COLOR: red, root or a
# password gets in; yellow, an account that cannot log in; green, closed
ssh_dot() { printf '%s●%s %s' "$1" "$C_RESET" "$2"; }

# ssh_keys_words — « 2 keys », or the program that gives them (after
# ssh_account_state)
ssh_keys_words() {
    if ((SSH_STATE_COMMAND)); then
        t 'keys given by a program'
    elif ((SSH_STATE_KEYS == 0)); then
        t '0 keys'
    elif ((SSH_STATE_KEYS == 1)); then
        t '1 key'
    else
        t '%s keys' "$SSH_STATE_KEYS"
    fi
}

# ssh_admin_words — an administrator: red, its password gets in; yellow,
# neither password nor key (it cannot log in); green, keys only
ssh_admin_words() {
    local color=$C_GREEN password
    if [[ -z $SSH_STATE_ROOT ]]; then
        ssh_dot "$C_YELLOW" "$(t 'sshd -T gives no answer')"
        return 0
    fi
    password=$(t 'password refused')
    if ((SSH_STATE_PASSWORD)); then
        color=$C_RED
        password=$(t 'password allowed')
    elif ((SSH_STATE_KEYS == 0 && SSH_STATE_COMMAND == 0)); then
        color=$C_YELLOW
    fi
    printf '%s · %s' "$(ssh_dot "$color" "$password")" "$(ssh_keys_words)"
}

# ssh_root_detail — how root gets in when sshd does not refuse it: its
# password, its keys if it has some
ssh_root_detail() {
    if ((SSH_STATE_PASSWORD)); then t 'password allowed'; else t 'password refused'; fi
    if ((SSH_STATE_KEYS || SSH_STATE_COMMAND)); then printf ' · %s' "$(ssh_keys_words)"; fi
}

# The administrators (never root, never the account of the seedbox), then
# root; a red frame first when sshd does not refuse root. SSH_ROOT_SHOWN:
# what sshd says of root (PermitRootLogin), for the menu.
SSH_ROOT_SHOWN=""
ssh_status() {
    local user width=4 root
    local -a admins=()
    mapfile -t admins < <(ssh_admin_accounts)
    ssh_account_state root
    SSH_ROOT_SHOWN=$SSH_STATE_ROOT
    case $SSH_STATE_ROOT in
        no) root=$(ssh_dot "$C_GREEN" "$(t 'SSH refused')") ;;
        # sshd -T stopped on an error of its settings: nothing to say of root
        "") root=$(ssh_dot "$C_YELLOW" "$(t 'sshd -T gives no answer')") ;;
        *)
            root="$(ssh_dot "$C_RED" "$(t 'SSH allowed')") · $(ssh_root_detail)"
            ui_box bad "$(t 'Root can log in by SSH')" "PermitRootLogin $SSH_STATE_ROOT · $(ssh_root_detail)"
            echo
            ;;
    esac
    # the names of both parts line up
    for user in "${admins[@]}"; do
        if ((${#user} > width)); then width=${#user}; fi
    done
    for user in "${admins[@]}"; do
        ssh_account_state "$user"
        ui_field_add "$user" "$(ssh_admin_words)"
    done
    if ((${#admins[@]} == 0)); then
        ui_field_add "" "$(ssh_dot "$C_YELLOW" "$(t 'no account that can use sudo')")"
    fi
    ui_group "$(t 'Administrators')" "$width"
    ui_field_add root "$root"
    ui_group root "$width"
}

# ssh_pick_account VARIABLE [root] — the account: the one running seedtunnel
# when it is the only one, otherwise asked (root in the list with « root »:
# to remove its keys). Status 1: back.
ssh_pick_account() {
    local _pick_var=$1 _pick_answer _pick_user i=0
    local -a _pick_accounts=()
    mapfile -t _pick_accounts < <(ssh_admin_accounts)
    if [[ ${2-} == root ]]; then _pick_accounts+=(root); fi
    if ((${#_pick_accounts[@]} == 0)); then
        warn 'No administrator account: create one that can use sudo first.'
        pause
        return 1
    fi
    if ((${#_pick_accounts[@]} == 1)); then
        printf -v "$_pick_var" '%s' "${_pick_accounts[0]}"
        return 0
    fi
    for _pick_user in "${_pick_accounts[@]}"; do
        i=$((i + 1))
        ui_menu_add "$i" "$_pick_user"
    done
    ui_menu_show
    echo
    while true; do
        ask_back _pick_answer 'Account' "" || return 1
        if [[ $_pick_answer =~ ^[0-9]{1,3}$ ]] && ((10#$_pick_answer >= 1 && 10#$_pick_answer <= ${#_pick_accounts[@]})); then
            printf -v "$_pick_var" '%s' "${_pick_accounts[10#$_pick_answer - 1]}"
            return 0
        fi
        warn 'Choose a number of the list.'
    done
}

ssh_menu_add_key() {
    local user=${1-} key
    banner
    section 'Add my public key'
    if [[ -z $user ]]; then ssh_pick_account user || return 0; fi
    ui_paragraph "$(t 'Paste the public key: one line, which starts with ssh-ed25519 or ssh-rsa, or the block saved by PuTTYgen. Never paste the private key.')"
    ui_paragraph "$(t 'Your key is a .ppk file of PuTTY? Open it in PuTTYgen: the public key is in the frame at the top.')"
    ui_paragraph "$(t 'Linux or macOS: your public key is in ~/.ssh/id_ed25519.pub (no key? ssh-keygen -t ed25519).')"
    echo
    if ssh_ask_public_key key; then
        ssh_keys_import "$user" - <<<"$key"
        pause
    fi
}

ssh_menu_new_key() {
    local user=${1-}
    banner
    section 'Create a key on the server'
    if [[ -z $user ]]; then ssh_pick_account user || return 0; fi
    ui_box warn "$(t 'Create a key on the server')" \
        "$(t 'Its private part goes once through a one-time link: a key made on your own computer never leaves it, which is safer (choice 1).')"
    echo
    if confirm 'Create the key?' y; then
        ssh_key_new "$user"
        pause
    fi
}

# My keys: the keys of an account (root too), one removed by its number
ssh_menu_keys() {
    local user=${1-} number
    banner
    section 'My keys'
    if [[ -z $user ]]; then ssh_pick_account user root || return 0; fi
    while true; do
        banner
        section 'My keys'
        ui_paragraph "$(t 'The keys that open SSH for %s:' "$user")"
        echo
        ssh_keys_show "$user"
        echo
        [[ -n $(ssh_key_entries "$user") ]] || {
            pause
            return 0
        }
        ask_back number 'Key to remove (number)' "" || return 0
        if [[ ! $number =~ ^[0-9]{1,4}$ ]]; then
            warn 'Choose a number of the list.'
            pause
            continue
        fi
        if confirm "$(t 'Remove the key %s of %s?' "$number" "$user")" n; then
            # a refusal comes back here, the menu stays
            subshell_run ssh_key_remove "$user" "$number"
            pause
        fi
    done
}

# Interactive SSH entry shares the access views; command syntax is unchanged.
ssh_menu() { access_menu; }

# ssh_cli_account [ACCOUNT] — the account named, or the one running seedtunnel
ssh_cli_account() {
    local user=${1:-${SUDO_USER:-}}
    [[ -n $user ]] || die 'Which account? Add it at the end of the command (seedtunnel ssh key list ACCOUNT, for example).'
    getent passwd "$user" >/dev/null || die 'Account not found: %s' "$user"
    printf '%s' "$user"
}

# seedtunnel ssh <command> (the account read first: a stop inside « $( ) »
# given as an argument would not stop the command)
ssh_cli() {
    local user
    case "${1-} ${2-}" in
        " ")
            if [[ -t 0 ]]; then
                require_terminal
                ssh_menu
            else
                ssh_status
            fi
            ;;
        "status ")
            cli_takes 1 "ssh status" "$@"
            ssh_status
            ;;
        "rules ")
            cli_takes 1 "ssh rules" "$@"
            ssh_rules_show
            ;;
        "key add")
            cli_takes 4 "ssh key add" "$@"
            [[ -n ${3-} ]] || die 'Usage: seedtunnel ssh key add FILE.pub [ACCOUNT]'
            user=$(ssh_cli_account "${4-}") || exit 1
            ssh_keys_import "$user" "$3"
            ;;
        "key new")
            cli_takes 3 "ssh key new" "$@"
            user=$(ssh_cli_account "${3-}") || exit 1
            ssh_key_new "$user"
            ;;
        "key list")
            cli_takes 3 "ssh key list" "$@"
            user=$(ssh_cli_account "${3-}") || exit 1
            ssh_keys_show "$user"
            ;;
        "key remove")
            cli_takes 4 "ssh key remove" "$@"
            [[ -n ${3-} ]] || die 'Usage: seedtunnel ssh key remove NUMBER [ACCOUNT]'
            user=$(ssh_cli_account "${4-}") || exit 1
            ssh_key_remove "$user" "$3"
            ;;
        "root off")
            cli_takes 2 "ssh root off" "$@"
            if [[ -t 0 ]]; then INTERACTIVE=1; fi
            ssh_root_off
            ;;
        "password off")
            cli_takes 2 "ssh password off" "$@"
            if [[ -t 0 ]]; then INTERACTIVE=1; fi
            ssh_password_off
            ;;
        "password on")
            cli_takes 2 "ssh password on" "$@"
            ssh_password_on
            ;;
        *) die 'Usage: seedtunnel ssh [status | rules | key add FILE.pub|new|list|remove NUMBER [ACCOUNT] | root off | password off|on]' ;;
    esac
}
