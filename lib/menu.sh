#!/usr/bin/env bash
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
    elif diskguard_stopped; then
        ui_status_add bad Seedbox "$(t 'halted')" "$(t 'disk almost full')"
    elif ! systemctl is-active --quiet transmission-daemon 2>/dev/null; then
        ui_status_add bad Seedbox "$(t 'halted')"
    elif ! systemctl is-active --quiet nginx 2>/dev/null; then
        ui_status_add bad Seedbox "$(t 'problem')" "$(t 'nginx stopped')"
    else
        ui_status_add ok Seedbox "$(t 'running')"
    fi
}

# On: the rules are loaded, refuse by default, and nothing the settings need is
# missing (what « seedtunnel firewall rules » checks)
home_firewall() {
    local name rules
    name=$(t 'Firewall')
    if ! firewall_enabled; then
        ui_status_add warn "$name" "$(t 'off')"
        return 0
    fi
    rules=$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null || true)
    if [[ -n $rules ]] && firewall_refuses_by_default <<<"$rules" && [[ -z $(firewall_rules_missing "$rules" 2>&1) ]]; then
        ui_status_add ok "$name" "$(t 'on')"
    else
        ui_status_add bad "$name" "$(t 'problem')" "$(t 'firewall: see its rules')"
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
    detail=$(t '%s free' "$(human_size "$avail")")
    if [[ $folder != / && $(df --output=target "$folder" 2>/dev/null | tail -n 1) != "$(df --output=target / 2>/dev/null | tail -n 1)" ]]; then
        read -r system_size system_avail < <(df -B1 --output=size,avail / 2>/dev/null | tail -n 1) || true
        if [[ $system_size =~ ^[0-9]+$ && $system_avail =~ ^[0-9]+$ ]] && ((system_size > 0)); then
            disk_level "$system_size" "$system_avail"
            if [[ $DISK_LEVEL != ok ]]; then
                detail+=" · $(t 'system: %s free' "$(human_size "$system_avail")")"
                if [[ $DISK_LEVEL == bad || $level == ok ]]; then level=$DISK_LEVEL; fi
            fi
        fi
    fi
    if [[ $level == ok ]]; then level=info; fi
    ui_status_add "$level" "$(t 'Disk')" "$(t '%s%%' "$used")" "$detail"
}

# Up to date: a backup (by hand or weekly) less than 8 days old. Failed: the
# last weekly backup failed, or it has no passphrase (the next one will fail).
home_backup() {
    local name latest age when=""
    name=$(t 'Backup')
    latest=$(backup_latest || true)
    age=$(file_age_days "$latest")
    if [[ -n $age ]]; then when=$(days_ago "$age"); fi
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
    elif ((age < 8)); then
        ui_status_add ok "$name" "$(t 'recent')" "$(t 'last backup %s' "$when")" "$when"
    else
        ui_status_add warn "$name" "$(t 'old')" "$(t 'last backup %s' "$when")" "$when"
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
        UI_PLACE=()
        ui_screen
        ui_header
        ui_rule
        home_status
        echo
        if vpn_installed; then ui_menu_add 1 "$(t 'Manage the VPN')"; else ui_menu_add 1 "$(t 'Install the VPN')"; fi
        if seedbox_installed; then ui_menu_add 2 "$(t 'Manage the seedbox')"; else ui_menu_add 2 "$(t 'Install the seedbox')"; fi
        ui_menu_add 3 "$(t 'Firewall')"
        ui_menu_add 4 "$(t 'Diagnostics')"
        ui_menu_gap
        ui_menu_add 5 "$(t 'Backup / restore')"
        ui_menu_add 6 "$(t 'Update seedtunnel')"
        ui_menu_add 7 "$(t 'Restart the server')"
        ui_menu_gap
        ui_menu_add l 'Language / Langue'
        ui_menu_show
        echo
        ui_menu_ask choice
        case ${choice,,} in
            1) ui_action vpn_main ;;
            2) ui_action seedbox_main ;;
            3) ui_action firewall_menu ;;
            4) ui_action doctor_main ;;
            5) ui_action backup_menu ;;
            6) update_main ;;
            7) reboot_server ;;
            l) language_menu ;;
            q) ui_quit ;;
        esac
    done
}
