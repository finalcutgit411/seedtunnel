#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Access menus only: observe the target, then call the existing SSH/SFTP actions.
# Opening or refreshing a view never applies a policy or prepares a download site.

# access_key_choices — what an SSH key is, in words anyone can follow, and the
# two ways to get one: the public key of a key the user already has (the
# safest), or a new key made by seedtunnel (the simplest); then « Remove a key »
access_key_choices() {
    ui_choices 1 "$(t 'I already have a key')" \
        "$(t 'paste its public key (.pub file): the private key never leaves your computer. The safest.')" \
        2 "$(t 'I have no key')" \
        "$(t 'seedtunnel creates one and gives you the private key through a one-time link. The simplest.')"
    ui_menu_add 3 "$(t 'Remove a key')"
}

# Navigation must not recreate a configured account deleted outside seedtunnel.
access_seedbox_require_account() {
    seedbox_require_installed
    getent passwd "$SEEDBOX_USER" >/dev/null || die 'Account not found: %s' "$SEEDBOX_USER"
}

access_sftp_state() {
    if ! getent passwd "$SEEDBOX_USER" >/dev/null; then
        ssh_dot "$C_YELLOW" "$(t 'Account not found: %s' "$SEEDBOX_USER")"
        return 0
    fi
    ssh_account_state "$SEEDBOX_USER"
    if [[ -z $SSH_STATE_ROOT ]]; then
        ssh_dot "$C_YELLOW" "$(t 'sshd -T gives no answer')"
        return 0
    fi
    if ((SSH_STATE_PASSWORD)); then
        ssh_dot "$C_YELLOW" "$(t 'password allowed')"
    else
        ssh_dot "$C_GREEN" "$(t 'password refused')"
    fi
    printf ' · %s' "$(ssh_keys_words)"
}

access_menu_show() {
    ssh_status
    echo
    if seedbox_installed; then
        ui_field_add "$SEEDBOX_USER" "$(access_sftp_state)"
        ui_group SFTP
        ui_field_add "$SEEDBOX_USER" "$(t 'Password authentication (configured, not checked)')"
        ui_group "$(t 'Web / Transmission')"
    else
        ui_paragraph "$(t 'Seedbox not installed: SFTP and web access are unavailable.')"
    fi
    echo
    ui_menu_add 1 "$(t 'SSH accounts and keys')"
    ui_menu_add 2 "$(t 'SFTP access and client profiles')"
    ui_menu_add 3 "$(t 'Seedbox credentials (web / SFTP)')"
    ui_menu_add 4 "$(t 'SSH rules in force')"
    ui_menu_add 5 "$(t 'SSH policy: passwords and root')"
    ui_menu_show
}

access_menu() {
    local choice
    while true; do
        seedbox_load
        UI_PLACE=("$(t 'Access and keys')")
        ui_top "${UI_PLACE[@]}"
        access_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action access_ssh_menu ;;
            2) ui_action access_sftp_menu ;;
            3) ui_action access_credentials_menu ;;
            4) ui_action ssh_rules_menu ;;
            5) ui_action access_policy_menu ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# Only the current eligible administrators, never a fallback to root or SFTP.
access_admin_available() {
    local account
    while IFS= read -r account; do
        [[ $account != "$1" ]] || return 0
    done < <(ssh_admin_accounts)
    return 1
}

access_ssh_menu() {
    local choice account i
    local -a accounts=()
    while true; do
        seedbox_load
        mapfile -t accounts < <(ssh_admin_accounts)
        UI_PLACE=("$(t 'Access and keys')" "$(t 'SSH accounts and keys')")
        ui_top "${UI_PLACE[@]}"
        if ((${#accounts[@]} == 0)); then
            warn 'No administrator account: create one that can use sudo first.'
            pause
            return 0
        fi
        if ((${#accounts[@]} == 1)); then
            ui_action access_ssh_keys_menu "${accounts[0]}"
            return 0
        fi
        for i in "${!accounts[@]}"; do
            account=${accounts[i]}
            ui_menu_add "$((i + 1))" "$account"
        done
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
        if [[ $choice =~ ^[0-9]{1,3}$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#accounts[@]})); then
            ui_action access_ssh_keys_menu "${accounts[10#$choice - 1]}"
        fi
    done
}

access_ssh_keys_show() {
    local account=$1
    ssh_account_state "$account"
    ui_field_add "$(t 'Account')" "$account"
    ui_field_add SSH "$(ssh_admin_words)"
    ui_fields_show
    echo
    if [[ -n $SSH_STATE_ROOT ]]; then
        ssh_keys_show "$account"
        echo
        if [[ $account != root ]]; then access_key_choices; else ui_menu_add 3 "$(t 'Remove a key')"; fi
        ui_menu_show
    fi
}

access_ssh_keys_menu() {
    local account=$1 choice known
    while true; do
        seedbox_load
        if [[ $account != root ]] && ! access_admin_available "$account"; then
            warn 'Administrator account %s is no longer available.' "$account"
            pause
            return 0
        fi
        UI_PLACE=("$(t 'Access and keys')" SSH "$account")
        ui_top "${UI_PLACE[@]}"
        access_ssh_keys_show "$account"
        known=$SSH_STATE_ROOT
        echo
        ui_menu_ask choice back
        if [[ $choice =~ ^[1-3]$ && $account != root ]] && ! access_admin_available "$account"; then
            warn 'Administrator account %s is no longer available.' "$account"
            pause
            return 0
        fi
        case ${choice,,} in
            1) if [[ -n $known && $account != root ]]; then ui_action ssh_menu_add_key "$account"; fi ;;
            2) if [[ -n $known && $account != root ]]; then ui_action ssh_menu_new_key "$account"; fi ;;
            3) if [[ -n $known ]]; then ui_action ssh_menu_keys "$account"; fi ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

access_sftp_show() {
    local port=$1 fingerprint=$2
    seedbox_sftp_card "$port" "$fingerprint" ""
    ui_field_add SFTP "$(access_sftp_state)"
    ui_fields_show
    echo
    sftp_keys_list
    echo
    access_key_choices
    ui_menu_add 4 "$(t 'WinSCP profile')"
    ui_menu_add 5 "$(t 'FileZilla profile')"
    ui_menu_add 6 "$(t 'Allow / refuse the password in SFTP')"
    ui_menu_show
}

access_sftp_menu() {
    local choice account port fingerprint
    local -a parent=("${UI_PLACE[@]}")
    seedbox_load
    access_seedbox_require_account
    account=$SEEDBOX_USER
    while true; do
        seedbox_load
        access_seedbox_require_account
        if [[ $SEEDBOX_USER != "$account" ]]; then
            warn 'The seedbox account changed: open its access screen again.'
            pause
            return 0
        fi
        UI_PLACE=("${parent[@]}" SFTP "$account")
        ui_top "${UI_PLACE[@]}"
        port=$(ssh_first_port)
        port=${port:-22}
        fingerprint=$(host_key_fingerprint)
        access_sftp_show "$port" "$fingerprint"
        echo
        ui_menu_ask choice back
        if [[ $choice =~ ^[1-6]$ ]]; then
            seedbox_load
            access_seedbox_require_account
            if [[ $SEEDBOX_USER != "$account" ]]; then
                warn 'The seedbox account changed: open its access screen again.'
                pause
                return 0
            fi
        fi
        case ${choice,,} in
            1) ui_action sftp_key_add_screen ;;
            2) ui_action sftp_key_new_screen ;;
            3) ui_action sftp_keys_menu_remove ;;
            4) ui_action seedbox_sftp_profile winscp "$port" ;;
            5) ui_action seedbox_sftp_profile filezilla "$port" ;;
            6) ui_action access_sftp_password ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

access_sftp_password() {
    banner
    section 'Allow / refuse the password in SFTP'
    ui_field_add "$(t 'Account')" "$SEEDBOX_USER"
    ui_field_add "$(t 'SFTP password')" "$(sftp_password_state)"
    ui_fields_show
    ui_paragraph "$(t 'This changes only SFTP password access. The web password and administrator SSH policy stay as they are.')"
    if confirm 'Change SFTP password access?' n; then sftp_keys_menu_password; fi
}

access_credentials_show() {
    ui_field_add "$(t 'Account')" "$SEEDBOX_USER"
    ui_field_add "$(t 'Web / Transmission')" "$(t 'Password authentication (configured, not checked)')"
    ui_field_add SFTP "$(access_sftp_state)"
    ui_fields_show
    echo
    ui_paragraph "$(t 'Seedbox credentials are shared by web/Transmission and SFTP when its password is allowed. Changing them may affect both accesses.')"
    ui_menu_add 1 "$(t 'Change the user or the password')"
    ui_menu_show
}

access_credentials_menu() {
    local choice account
    local -a parent=("${UI_PLACE[@]}")
    while true; do
        seedbox_load
        access_seedbox_require_account
        account=$SEEDBOX_USER
        UI_PLACE=("${parent[@]}" "$(t 'Seedbox credentials (web / SFTP)')")
        ui_top "${UI_PLACE[@]}"
        access_credentials_show
        echo
        ui_menu_ask choice back
        if [[ $choice == 1 ]]; then
            seedbox_load
            access_seedbox_require_account
            if [[ $SEEDBOX_USER != "$account" ]]; then
                warn 'The seedbox account changed: open its access screen again.'
                pause
                return 0
            fi
        fi
        case ${choice,,} in
            1) ui_action seedbox_menu_credentials ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

access_policy_show() {
    ssh_status
    echo
    ui_paragraph "$(t 'SSH password policy applies to the administrators. Refusing passwords also refuses root; accepting passwords again keeps root refused.')"
    if [[ $(ssh_access_mode) == keys ]]; then
        ui_menu_add 1 "$(t 'Accept the passwords again')"
    else
        ui_menu_add 1 "$(t 'Refuse the passwords (keys only)')"
    fi
    if [[ $SSH_ROOT_SHOWN != no ]]; then ui_menu_add 2 "$(t 'Refuse root in SSH')"; fi
    ui_menu_add 3 "$(t 'Root keys (see, remove)')"
    ui_menu_show
}

access_policy_menu() {
    local choice
    while true; do
        seedbox_load
        UI_PLACE=("$(t 'Access and keys')" "$(t 'SSH policy: passwords and root')")
        ui_top "${UI_PLACE[@]}"
        access_policy_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) if [[ $(ssh_access_mode) == keys ]]; then ui_action ssh_password_on; else ui_action ssh_password_off; fi ;;
            2) if [[ $SSH_ROOT_SHOWN != no ]]; then ui_action ssh_root_off; fi ;;
            3) ui_action access_ssh_keys_menu root ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}
