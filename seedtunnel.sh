#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — WireGuard VPN + secure seedbox, for Debian 12 / 13 and Ubuntu 24.04 / 26.04
#
#  VPN     : WireGuard, one open port per client, QR codes for phones
#  Seedbox : Transmission behind nginx (HTTPS with Let's Encrypt), SFTP access,
#            fail2ban, automatic security updates, weekly backups
#
#  Without arguments: interactive menu. With a command: usable from scripts
#  (see « seedtunnel help »). Messages in English or in French.
#
#  Copyright (C) 2016-2026 FinalCut
#  Free software under the GNU General Public License, version 3 or any later
#  version (see LICENSE): you may use, study, change and share it; what you
#  share stays under the same license, with its source code.
# =============================================================================
set -Eeuo pipefail

# On Debian, « su » without a dash keeps the PATH of the user, without
# /usr/sbin: sysctl, useradd, nft… would not be found.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

APP_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/i18n.sh
. "$APP_DIR/lib/i18n.sh"
# shellcheck source=lib/ui.sh
. "$APP_DIR/lib/ui.sh"
# shellcheck source=lib/vpn.sh
. "$APP_DIR/lib/vpn.sh"
# shellcheck source=lib/seedbox.sh
. "$APP_DIR/lib/seedbox.sh"
# shellcheck source=lib/firewall.sh
. "$APP_DIR/lib/firewall.sh"
# shellcheck source=lib/share.sh
. "$APP_DIR/lib/share.sh"
# shellcheck source=lib/diskguard.sh
. "$APP_DIR/lib/diskguard.sh"
# shellcheck source=lib/backup.sh
. "$APP_DIR/lib/backup.sh"
# shellcheck source=lib/update.sh
. "$APP_DIR/lib/update.sh"
# shellcheck source=lib/doctor.sh
. "$APP_DIR/lib/doctor.sh"
# shellcheck source=lib/menu.sh
. "$APP_DIR/lib/menu.sh"

error_trap_on

# --- Options ---------------------------------------------------------------------------
ARGUMENTS=()
need_value() { [[ -n ${2-} && ${2-} != -* ]] || die 'The option %s needs a value.' "$1"; }

# language first, so that even the errors below are translated
i18n_init

while (($#)); do
    case $1 in
        -y | --yes) OPT_YES=1 ;;
        -c | --config)
            need_value "$1" "${2-}"
            OPT_CONFIG_FILE=$2
            shift
            ;;
        --staging) OPT_STAGING=1 ;;
        --qr) OPT_QR=1 ;;
        --link) OPT_LINK=1 ;;
        --purge-data) OPT_PURGE_DATA=1 ;;
        --output)
            need_value "$1" "${2-}"
            OPT_OUTPUT_FILE=$2
            shift
            ;;
        --passphrase-file)
            need_value "$1" "${2-}"
            OPT_PASSPHRASE_FILE=$2
            shift
            ;;
        --user)
            need_value "$1" "${2-}"
            OPT_NEW_USER=$2
            shift
            ;;
        -h | --help)
            text usage
            exit 0
            ;;
        --)
            shift
            ARGUMENTS+=("$@")
            break
            ;;
        # « - » alone means standard input (e.g. sftp-key add -)
        -) ARGUMENTS+=("$1") ;;
        -*) die 'Unknown option: %s   (help: seedtunnel help)' "$1" ;;
        *) ARGUMENTS+=("$1") ;;
    esac
    shift
done
set -- "${ARGUMENTS[@]}"

case ${1-} in
    help)
        text usage
        exit 0
        ;;
    version)
        printf 'seedtunnel %s\n' "$APP_VERSION"
        exit 0
        ;;
esac

# Unknown command, or arguments too many: refused before anything is done (no
# folder created, no lock taken). The commands of vpn, seedbox, firewall and
# backup check their own arguments.
case ${1-} in
    apply | doctor | diskguard-check | diskguard-prestart) MAX_ARGUMENTS=1 ;;
    restore | language | update) MAX_ARGUMENTS=2 ;;
    "" | vpn | seedbox | firewall | backup) MAX_ARGUMENTS=0 ;;
    *) die 'Unknown command: %s   (help: seedtunnel help)' "$1" ;;
esac
if ((MAX_ARGUMENTS && $# > MAX_ARGUMENTS)); then
    die 'Too many arguments for « seedtunnel %s »: %s   (help: seedtunnel help)' "$1" "${*:MAX_ARGUMENTS+1}"
fi
if [[ ${1-} == update && -n ${2-} && ${2-} != back ]]; then die 'Usage: seedtunnel update [back]'; fi

check_system
# Commands that change nothing (or only add a backup file) do not wait for the
# lock: they work even if a menu was left open in another window.
case "${1-} ${2-} ${3-}" in
    "diskguard-check  " | "diskguard-prestart  " | "backup  " | "backup list " | "backup auto run" | "backup auto status" | "backup auto " | "firewall rules ") ;;
    # a link to the report changes the site of the seedbox: it waits
    "doctor  ")
        if ((OPT_LINK)); then
            take_lock
            packages_record_init
        fi
        ;;
    *)
        # a full system disk: said before anything is written
        disk_space_check
        take_lock
        packages_record_init
        ;;
esac
install_shortcut
vpn_load
seedbox_load
firewall_load

case ${1-} in
    "")
        require_terminal
        language_first_run
        main_menu
        ;;
    vpn) vpn_cli "${@:2}" ;;
    seedbox) seedbox_cli "${@:2}" ;;
    firewall) firewall_cli "${@:2}" ;;
    doctor)
        doctor_main
        ((DOCTOR_ERRORS == 0)) || exit 1
        ;;
    backup) backup_cli "${@:2}" ;;
    # empty passphrase or « no »: back without doing anything
    restore) restore_cli "${2-}" ;;
    update) update_cli "${2-}" ;;
    apply) apply_main ;;
    language) language_cli "${2-}" ;;
    diskguard-check) diskguard_check ;;
    diskguard-prestart) diskguard_prestart || exit 1 ;;
esac
