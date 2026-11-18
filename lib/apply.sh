#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Installed-code orchestration only. Version selection and rollback live in
# update.sh; update_save_previous and update_log_installed remain explicit
# bookkeeping dependencies. Feature applications own their activation rules.

# Puts the server back in the state saved in /etc/seedtunnel, with the settings
# of the installed version: after an update, or if something was changed by
# hand. As when the installation runs again, only the files that change are
# written and only the services concerned are restarted.
apply_main() {
    local count=0
    banner
    section 'Applying the configuration'
    update_save_previous
    rights_apply
    log_rotation_apply
    ssh_access_apply
    if vpn_installed; then
        vpn_apply
        count=$((count + 1))
    fi
    if seedbox_installed; then
        seedbox_apply
        count=$((count + 1))
    fi
    links_load
    if links_site_on; then links_apply; fi
    if firewall_enabled; then
        firewall_refresh
        count=$((count + 1))
    fi
    if [[ -r $BACKUP_PASSPHRASE_FILE ]]; then backup_auto_install_units; fi
    update_log_installed
    if ((count)); then
        ok 'Configuration up to date (seedtunnel %s).' "$APP_VERSION"
    else
        say 'Nothing to apply: neither VPN, nor seedbox, nor firewall.'
    fi
}

# --- Removing seedtunnel entirely ----------------------------------------------

# Where the units of seedtunnel are (a variable for the tests)
APP_UNITS_DIR="/etc/systemd/system"

# seedtunnel uninstall [--yes] [--purge-data] [--purge-backups] — the seedbox,
# the VPN and the firewall go as with their own commands (one that fails stops
# everything: running it again goes on from there), then what is left of
# seedtunnel: its units, settings, log and its rotation, shortcut and code.
# Kept: the backups (--purge-backups deletes them), the data of the seedbox
# (--purge-data), the SSH access of the administrators (removing it would let
# root in again without a word), the packages of the system and the security
# updates of Debian. Asked once, no by default.
uninstall_main() {
    local unit path keep_code=0
    local -a lines=()
    if [[ -e $APP_DIR/.git ]]; then keep_code=1; fi
    section 'Remove seedtunnel entirely'
    lines+=("$(t 'Everything seedtunnel set up goes: the seedbox, the VPN and all its clients, the firewall, the weekly backup, the settings, the log and the code.')")
    if seedbox_installed && ((!OPT_PURGE_DATA)); then
        lines+=("$(t 'The data of the seedbox stay in %s (--purge-data deletes them).' "$SEEDBOX_DATA_DIR")")
    fi
    if ((OPT_PURGE_BACKUPS)); then
        lines+=("$(t 'The backups in %s are deleted too: copy the ones to keep elsewhere first (seedtunnel backup share).' "$BACKUP_DIR")")
    else
        lines+=("$(t 'The backups stay in %s (--purge-backups deletes them).' "$BACKUP_DIR")")
    fi
    lines+=("$(t 'The SSH access of the administrators stays as it is (root refused).')")
    danger "$(t 'Remove seedtunnel entirely')" "${lines[@]}"
    if ! confirm 'Remove seedtunnel entirely?' n; then return 0; fi
    # asked once: the parts below do not ask again
    local OPT_YES=1
    if seedbox_installed; then seedbox_uninstall; fi
    if vpn_installed; then vpn_uninstall; fi
    if firewall_enabled || [[ -e $FIREWALL_UNIT ]]; then firewall_disable; fi
    if backup_auto_enabled || [[ -e $BACKUP_TIMER ]]; then backup_auto_disable; fi
    echo
    # what a part may have left (a unit of an older version, a link running)
    log_run 'Stopping the download links in progress' systemctl stop 'seedtunnel-share-*'
    for unit in "$APP_UNITS_DIR"/seedtunnel-*.service "$APP_UNITS_DIR"/seedtunnel-*.timer; do
        [[ -f $unit && ! -L $unit ]] || continue
        log_run 'Stopping a unit of seedtunnel' systemctl disable --now "${unit##*/}"
        rm -f -- "$unit"
    done
    systemctl daemon-reload 2>/dev/null || true
    rm -f -- "$LOGROTATE_FILE" "$LOGIN_ALERTS_FILE"
    rm -rf -- "${APP_STATE_DIR:?}" "$APP_STATE_DIR".before-restore-*
    if ((OPT_PURGE_BACKUPS)); then rm -rf -- "${BACKUP_DIR:?}"; fi
    if [[ -L $APP_SHORTCUT && $(readlink -- "$APP_SHORTCUT") == "$APP_DIR/seedtunnel.sh" ]]; then rm -f -- "$APP_SHORTCUT"; fi
    # the code last: the running script keeps its files open
    if ((!keep_code)) && [[ $APP_DIR == /?* && -f $APP_DIR/seedtunnel.sh && -f $APP_DIR/lib/common.sh ]]; then
        for path in "$APP_DIR.old" "$APP_DIR.old.tmp" "$APP_DIR.previous" "$APP_DIR.failed"; do
            if [[ -d $path && ! -L $path ]]; then rm -rf -- "$path"; fi
        done
        rm -rf -- "$APP_DIR"
    fi
    # the log, once nothing writes in it any more
    rm -f -- "$APP_LOG" "$APP_LOG".*
    ok 'seedtunnel removed.'
    if ((keep_code)); then say '%s is a git repository: left in place.' "$APP_DIR"; fi
    if ((!OPT_PURGE_BACKUPS)) && [[ -d $BACKUP_DIR ]]; then
        say 'The backups stay in %s: once copied elsewhere,  rm -rf %s' "$BACKUP_DIR" "$BACKUP_DIR"
    fi
    if [[ -f $SSH_ADMIN_CONF ]]; then
        say 'The SSH access of the administrators stays (%s): root refused, and the passwords if you refused them.' "$SSH_ADMIN_CONF"
    fi
    say 'The packages of the system (curl, jq, nftables…) and the security updates of Debian stay.'
}
