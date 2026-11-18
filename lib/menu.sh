#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — home screen of the menus: state of the server and main menu
#  Loaded by seedtunnel.sh: this file does nothing on its own.
# =============================================================================

# --- State of the server -------------------------------------------------------------
# Five blocks (lib/ui.sh): VPN, seedbox, firewall, disk, backup. Each state
# fits in 9 characters, in English and in French (tests/unit.sh checks it).

home_vpn() {
    if ! vpn_installed; then
        ui_status_add off VPN "$(t 'missing')"
    elif systemctl is-active --quiet "wg-quick@$VPN_INTERFACE" 2>/dev/null; then
        ui_status_add ok VPN "$(t 'running')" "$(t '%s of %s clients connected' "$(vpn_connected_count)" "$(vpn_count_clients)")"
    else
        ui_status_add bad VPN "$(t 'stopped')"
    fi
}

home_seedbox() {
    if ! seedbox_installed; then
        ui_status_add off Seedbox "$(t 'absent')"
        return 0
    fi
    local -A observation=()
    seedbox_observe observation
    if [[ ${observation[restore_hold]:-no} == yes ]]; then
        ui_status_add warn Seedbox "$(t 'unknown')" "$(t 'restore unfinished')"
    elif [[ ${observation[disk_state_invalid]:-no} == yes ]]; then
        ui_status_add warn Seedbox "$(t 'unknown')" "$(t 'guard state invalid')"
    elif [[ ${observation[disk_resume_unknown]:-no} == yes ]]; then
        ui_status_add warn Seedbox "$(t 'unknown')" "$(t 'restart unconfirmed')"
    elif [[ ${observation[disk_resume_failed]:-no} == yes ]]; then
        ui_status_add bad Seedbox "$(t 'halted')" "$(t 'restart failed')"
    elif [[ ${observation[disk_halt]} == yes ]]; then
        ui_status_add bad Seedbox "$(t 'halted')" "$(t 'disk almost full')"
    elif [[ ${observation[engine_state]} == unknown ]]; then
        ui_status_add warn Seedbox "$(t 'unknown')"
    elif [[ ${observation[engine_state]} != active ]]; then
        ui_status_add bad Seedbox "$(t 'halted')"
    elif [[ ${observation[nginx_state]} == unknown ]]; then
        ui_status_add warn Seedbox "$(t 'unknown')"
    elif [[ ${observation[nginx_state]} != active ]]; then
        ui_status_add bad Seedbox "$(t 'alert!')" "$(t 'nginx stopped')"
    elif [[ ${observation[storage_state]} == unknown ]]; then
        ui_status_add warn Seedbox "$(t 'alert!')" "$(t 'Free space for downloads unreadable (%s)' "${SEEDBOX_DATA_DIR-}")"
    else
        ui_status_add ok Seedbox "$(t 'running')"
    fi
}

# On: the rules are loaded, refuse by default, and nothing the settings need is
# missing; nothing else blocks the VPN (firewall_findings, said in full on the
# screen Firewall). An error: red; a warning, or off: yellow. The worst finding
# below the blocks.
home_firewall() {
    local name i level="" short=""
    name=$(t 'Firewall')
    firewall_findings
    for i in "${!FW_LEVELS[@]}"; do
        if [[ ${FW_LEVELS[i]} == bad ]]; then
            level=bad
            short=${FW_SHORTS[i]}
            break
        fi
        if [[ -z $level ]]; then
            level=warn
            short=${FW_SHORTS[i]}
        fi
    done
    if [[ $level == bad ]]; then
        ui_status_add bad "$name" "$(t 'alert!')" "$(t 'firewall: %s' "$short")" "$short"
    elif ! firewall_enabled; then
        ui_status_add warn "$name" "$(t 'off')" "${short:+$(t 'firewall: %s' "$short")}" "$short"
    elif [[ $level == warn ]]; then
        ui_status_add warn "$name" "$(t 'warning')" "$(t 'firewall: %s' "$short")" "$short"
    else
        ui_status_add ok "$name" "$(t 'on')"
    fi
}

# Used part of the disk of the downloads (of the system without seedbox).
# Downloads on another disk: the system disk counts too when it is short.
home_disk() {
    local folder=/ size="" avail="" used level detail system_size="" system_avail=""
    if seedbox_installed && [[ -d $SEEDBOX_DATA_DIR ]]; then folder=$SEEDBOX_DATA_DIR; fi
    read -r size avail < <(df -B1 --output=size,avail "$folder" 2>/dev/null | tail -n 1) || true
    if [[ ! $size =~ ^[0-9]+$ || ! $avail =~ ^[0-9]+$ ]] || ((size == 0)); then
        ui_status_add off "$(t 'Disk')" "?"
        return 0
    fi
    used=$(((size - avail) * 100 / size))
    disk_level "$size" "$avail"
    level=$DISK_LEVEL
    detail=$(t '%s free' "$(human_size_spaced "$avail")")
    if [[ $folder != / && $(df --output=target "$folder" 2>/dev/null | tail -n 1) != "$(df --output=target / 2>/dev/null | tail -n 1)" ]]; then
        read -r system_size system_avail < <(df -B1 --output=size,avail / 2>/dev/null | tail -n 1) || true
        if [[ $system_size =~ ^[0-9]+$ && $system_avail =~ ^[0-9]+$ ]] && ((system_size > 0)); then
            disk_level "$system_size" "$system_avail"
            if [[ $DISK_LEVEL != ok ]]; then
                detail+=" · $(t 'system: %s free' "$(human_size_spaced "$system_avail")")"
                if [[ $DISK_LEVEL == bad || $level == ok ]]; then level=$DISK_LEVEL; fi
            fi
        fi
    fi
    if [[ $level == ok ]]; then level=info; fi
    ui_status_add "$level" "$(t 'Disk')" "$(t '%s%%' "$used")" "$detail"
}

# Up to date: a backup less than 8 days old, with the weekly backup on.
# Manual: the same, the weekly backup off. Failed: the last weekly backup
# failed, or it has no passphrase (the next one will fail).
home_backup() {
    local name latest age when="" off=""
    name=$(t 'Backup')
    latest=$(backup_latest || true)
    age=$(file_age_days "$latest")
    if [[ -n $age ]]; then when=$(days_ago "$age"); fi
    # without the weekly backup, a backup made by hand is said « manual », in
    # yellow (the word says it too, without colors)
    if ! backup_auto_enabled && { vpn_installed || seedbox_installed; }; then off=" · $(t 'weekly backup off')"; fi
    if backup_auto_enabled && systemctl is-failed --quiet seedtunnel-backup.service 2>/dev/null; then
        ui_status_add bad "$name" "$(t 'failed')" "$(t 'the weekly backup failed')"
    elif backup_auto_enabled && [[ ! -s $BACKUP_PASSPHRASE_FILE ]]; then
        ui_status_add bad "$name" "$(t 'failed')" "$(t 'weekly backup without its passphrase')"
    elif [[ -z $age ]]; then
        if vpn_installed || seedbox_installed; then
            ui_status_add warn "$name" "$(t 'none yet')" "$(t 'no backup yet')"
        else
            ui_status_add off "$name" "$(t 'none yet')"
        fi
    elif ((age >= 8)); then
        ui_status_add warn "$name" "$(t 'old')" "$(t 'last backup %s' "$when")$off" "$when"
    elif [[ -n $off ]]; then
        ui_status_add warn "$name" "$(t 'manual')" "$(t 'last backup %s' "$when")$off" "$when"
    else
        ui_status_add ok "$name" "$(t 'recent')" "$(t 'last backup %s' "$when")" "$when"
    fi
}

home_status() {
    home_vpn
    home_seedbox
    home_firewall
    home_disk
    home_backup
    ui_status_show
    if restore_interrupted; then
        echo
        ui_print "  $C_RED✘ $(t 'A restore did not finish: the settings may be incomplete. See  seedtunnel doctor')$C_RESET"
    fi
}

# --- Main menu ---------------------------------------------------------------------
# Every entry runs in a subshell (ui_action): an error comes back here. Except
# the update (it hands the lock over to the new version, then leaves), the
# restart and the language (which must stay chosen).

main_menu() {
    local choice
    while true; do
        vpn_load
        seedbox_load
        links_load
        # a restore (in a subshell) may have brought another language back
        language_reload
        UI_PLACE=()
        ui_screen
        ui_header
        ui_rule
        home_status
        echo
        home_menu_choices
        ui_menu_show
        echo
        ui_menu_ask choice
        case ${choice,,} in
            1) ui_action vpn_main ;;
            2) ui_action seedbox_main ;;
            3) ui_action firewall_menu ;;
            4) ui_action access_menu ;;
            5) maintenance_menu ;;
            6) ui_action backup_menu ;;
            l) language_menu ;;
            q) ui_quit ;;
        esac
    done
}

# Shared by the real home screen and the text preview: one source for M0.
home_menu_choices() {
    ui_menu_add 1 VPN
    ui_menu_add 2 Seedbox
    ui_menu_add 3 "$(t 'Protection')"
    ui_menu_add 4 "$(t 'Access and keys')"
    ui_menu_add 5 "$(t 'Diagnostics and maintenance')"
    ui_menu_add 6 "$(t 'Backups and restore')"
    ui_menu_gap
    ui_menu_add l "$(t 'Language')"
}

maintenance_menu_show() {
    ui_field_add "$(t 'Installed version')" "$APP_VERSION"
    ui_fields_show
    echo
    ui_menu_add 1 "$(t 'Server diagnostics')"
    ui_menu_add 2 "$(t 'Update / previous version')"
    ui_menu_gap
    ui_menu_add 3 "$(t 'Restart the server')"
    ui_menu_show
}

maintenance_menu() {
    local choice
    while true; do
        UI_PLACE=("$(t 'Diagnostics and maintenance')")
        ui_top "${UI_PLACE[@]}"
        maintenance_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) ui_action doctor_main ;;
            # Keep the existing update/reboot process lifetime: never resume
            # old parent code after an update has replaced its files.
            2) update_menu ;;
            3) reboot_server ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}
