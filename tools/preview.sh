#!/usr/bin/env bash
# =============================================================================
#  seedtunnel — preview of the interface, with example data
#
#  Shows the screens of the menus as they will look, in your own terminal
#  (colors, width, accents). It changes nothing and installs nothing: no root,
#  no seedtunnel needed. The data (clients, sizes, addresses) are examples;
#  the name of the server and its version of Debian are the real ones.
#
#  Usage: tools/preview.sh [--fr | --en] [--no-color | --color] [--columns N]
#                          [--all]
#    without --all : one screen after the other (Enter: next, Q: quit)
#    --all         : every screen at once, without questions (to copy and
#                    paste, and for the tests)
#    --columns N   : as if the terminal had N columns
# =============================================================================
set -Eeuo pipefail

APP_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/i18n.sh
. "$APP_DIR/lib/i18n.sh"
# shellcheck source=lib/ui.sh
. "$APP_DIR/lib/ui.sh"
# vpn_last_connection: the column of the table of the clients
# shellcheck source=lib/vpn.sh
. "$APP_DIR/lib/vpn.sh"

trap 'on_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]:-}"' ERR

ALL=0
COLORS=""
LANGUAGE=""
SCREENS=0
CHOICE=""

# Free space of the examples (68 GB)
EXAMPLE_FREE=73014444032

# pv ENGLISH FRENCH — texts of the preview itself; those of the real menus go
# through t and lang/fr.txt, as in the menus (a unit test checks it)
pv() { if [[ $APP_LANG == fr ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# End of a screen: the question of the menu, or « Enter ↵ back » after an
# action. With --all, they are only shown. Status 1: the user wants to quit.
end_menu() {
    if ((ALL)); then
        ui_menu_keys "${1-}"
        ui_footer "${UI_KEYS[@]}"
        printf '%s\n' "$UI_PROMPT"
        return 0
    fi
    ui_menu_ask CHOICE "${1-}"
    [[ ${CHOICE,,} != q ]]
}

end_action() {
    if ((ALL)); then
        echo
        ui_print "  $C_GREY$(t 'Enter ↵ back · Q quit')$C_RESET"
        return 0
    fi
    ui_pause
}

top() {
    SCREENS=$((SCREENS + 1))
    if ((ALL)); then printf '\n=== %s ===\n' "$1"; fi
    ui_screen
    ui_header
    ui_rule
}

screen_home() {
    top home
    ui_status_add ok VPN "$(t 'running')" "$(t '%s of %s clients connected' 2 3)"
    ui_status_add ok Seedbox "$(t 'running')"
    ui_status_add ok "$(t 'Firewall')" "$(t 'on')"
    ui_status_add info "$(t 'Disk')" "$(t '%s%%' 62)" "$(t '%s free' "$(human_size_spaced "$EXAMPLE_FREE")")"
    ui_status_add ok "$(t 'Backup')" "$(t 'recent')" "$(t 'last backup %s' "$(days_ago 3)")" "$(days_ago 3)"
    ui_status_show
    echo
    ui_menu_add 1 "$(t 'Manage the VPN')"
    ui_menu_add 2 "$(t 'Manage the seedbox')"
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
    end_menu
}

# The same, as on a terminal of 60 columns (PuTTY made narrower)
screen_home_narrow() {
    local columns=${UI_COLUMNS-}
    UI_COLUMNS=61
    screen_home || {
        UI_COLUMNS=$columns
        return 1
    }
    UI_COLUMNS=$columns
}

screen_vpn() {
    top vpn
    ui_crumbs VPN
    echo
    ui_field_add "$(t 'State')" "$C_GREEN$(t 'running')$C_RESET"
    ui_field_add "$(t 'Address')" "${C_CYAN}203.0.113.10:51820$C_RESET (UDP)"
    ui_field_add Clients "$(t '%s (%s connected right now)' 3 2)"
    ui_field_add DNS "Quad9 · 9.9.9.9, 149.112.112.112"
    ui_fields_show
    echo
    ui_menu_add 1 "$(t 'Add a client')"
    ui_menu_add 2 "$(t 'Show a client (QR code, file)')"
    ui_menu_add 3 "$(t 'Download link for a client (one time only)')"
    ui_menu_add 4 "$(t 'Revoke a client')"
    ui_menu_add 5 "$(t 'Clients and connections')"
    ui_menu_gap
    ui_menu_add 6 "$(t 'Change the address or the port')"
    ui_menu_add 7 "$(t 'Change the DNS of the clients')"
    ui_menu_add 8 "$(t 'Restart the VPN')"
    ui_menu_add 9 "$(t 'Remove the VPN')"
    ui_menu_show
    echo
    end_menu back
}

screen_clients() {
    top clients
    ui_crumbs VPN "$(t 'Clients and connections')"
    echo
    ui_print "  $(t 'VPN running since %s.' '2026-11-11 02:08')"
    echo
    ui_table \
        "$(t 'CLIENT')"$'\t'IP$'\t'PORT$'\t'"$(t 'RECEIVED / SENT')"$'\t'"$(t 'LAST CONNECTION')" \
        "laptop"$'\t'"10.8.0.2"$'\t'"60001"$'\t'"$(human_size 1288490188) / $(human_size 356515840)"$'\t'"$(vpn_last_connection 12)" \
        "phone"$'\t'"10.8.0.3"$'\t'"60002"$'\t'"$(human_size 92274688) / $(human_size 12582912)"$'\t'"$(vpn_last_connection 420)" \
        "desktop"$'\t'"10.8.0.5"$'\t'"60004"$'\t'"$(human_size 4194304) / $(human_size 1048576)"$'\t'"$(vpn_last_connection 7200)" \
        "tablet"$'\t'"10.8.0.4"$'\t'"60003"$'\t'"$(human_size 0) / $(human_size 0)"$'\t'"$(vpn_last_connection -1)"
    end_action
}

screen_dns() {
    top dns
    ui_crumbs VPN "$(t 'Change the DNS of the clients')"
    echo
    ui_print "$(t 'In use: %s' "Quad9 · 9.9.9.9, 149.112.112.112")"
    echo
    ui_print "$(t 'DNS servers used by the VPN clients:')"
    ui_print "$(t '  1) Quad9      — blocks malicious domains (Swiss foundation)')"
    ui_print "$(t '  2) Cloudflare — usually the fastest')"
    ui_print "$(t '  3) DNS4EU     — European Union, blocks malicious domains')"
    ui_print "$(t '  4) AdGuard    — also blocks ads and trackers')"
    ui_print "$(t '  5) Other      — type the addresses')"
    ui_print "$(t '%s (empty = back)' "$(t 'Your choice [1-5]')"): 4"
    echo
    ui_print "  $(t 'Applying the configuration')… $C_GREEN$(t 'ok')$C_RESET"
    ui_print "$C_GREEN✔$C_RESET $(t 'DNS of the clients: %s.' "AdGuard · 94.140.14.14, 94.140.15.15")"
    ui_print "$C_YELLOW!$C_RESET $(t 'Each client keeps the old DNS until it imports its configuration again.')"
    end_action
}

screen_add() {
    top add
    ui_crumbs VPN "$(t 'Add a client')"
    echo
    ui_print "  $(t '%s (empty = back)' "$(t 'Client name (e.g. phone, laptop)')"): phone2"
    ui_print "  $(t 'Applying the configuration')… $C_GREEN$(t 'ok')$C_RESET"
    ui_print "  $(t 'Updating the firewall')… $C_GREEN$(t 'ok')$C_RESET"
    ui_print "$C_GREEN✔$C_RESET $(t 'Client "%s" created: IP %s, open port %s, file %s' phone2 10.8.0.5 60004 /etc/seedtunnel/vpn/clients/phone2.conf)"
    end_action
}

screen_danger() {
    local question
    top danger
    ui_crumbs VPN "$(t 'Revoke a client')"
    echo
    ui_box bad "$(t 'Revoke "%s"' laptop)" \
        "$(t 'This device will no longer be able to connect to the VPN.')" \
        "$(t 'Its file and its QR code stop working: this cannot be undone.')"
    echo
    question="$(t 'Revoke "%s" for good?' laptop) $(t '[y/N]')"
    if ((ALL)); then
        ui_print "  $question"
        end_action
        return 0
    fi
    IFS= read -r -p "  $question " CHOICE || exit 130
    printf '  %s\n' "$(pv '(preview: nothing was revoked)' "(aperçu : rien n'a été révoqué)")"
    end_action
}

screen_seedbox() {
    local ok="$C_GREEN●$C_RESET"
    top seedbox
    ui_crumbs Seedbox
    echo
    ui_field_add "$(t 'Web interface')" "${C_CYAN}https://seed.example.net/$C_RESET"
    ui_field_add "$(t 'Certificate')" "Let's Encrypt"
    ui_field_add SFTP "lancelot@seed.example.net · $(t '%s free%s of %s' "$C_GREEN$(human_size_spaced "$EXAMPLE_FREE")" "$C_RESET" "$(human_size_spaced 214748364800)")"
    ui_field_add "$(t 'SFTP password')" "$C_GREEN● $(t 'refused (keys only)')$C_RESET"
    ui_field_add Services "Transmission $ok · nginx $ok · fail2ban $ok"
    ui_fields_show
    echo
    ui_menu_add 1 "$(t 'Change the user or the password')"
    ui_menu_add 2 "$(t 'Domain name and HTTPS certificate')"
    ui_menu_add 3 "$(t 'SSH keys for SFTP')"
    ui_menu_add 4 "$(t 'SFTP connection: settings for WinSCP and FileZilla')"
    ui_menu_add 5 "$(t 'Banned IP addresses (fail2ban)')"
    ui_menu_gap
    ui_menu_add 6 "$(t 'Restart the services')"
    ui_menu_add 7 "$(t 'Remove the seedbox')"
    ui_menu_show
    echo
    end_menu back
}

screen_bans() {
    top bans
    ui_crumbs Seedbox "$(t 'Banned IP addresses (fail2ban)')"
    echo
    ui_table \
        ""$'\t'"$(t 'ADDRESS')"$'\t'JAIL$'\t'"$(t 'BANNED UNTIL')" \
        "1)"$'\t'"2001:db8::17"$'\t'"nginx-http-auth"$'\t'"03:48 $(t '(in %s min)' 18)" \
        "2)"$'\t'"203.0.113.7"$'\t'"sshd"$'\t'"04:12 $(t '(in %s min)' 42)" \
        "3)"$'\t'"198.51.100.23"$'\t'"recidive"$'\t'"2026-11-18 03:12 $(t '(in %s days)' 7)"
    echo
    ui_print "  $(t 'Bans since fail2ban started: %s.' 12)"
    ui_print "  $C_GREY$(t 'sshd = SSH/SFTP (1 h) · nginx-http-auth = web interface (1 h)')$C_RESET"
    ui_print "  $C_GREY$(t 'recidive = banned 3 times in 24 h (1 week)')$C_RESET"
    ui_print "  $C_GREY$(t 'Banned? The VPN still connects, and nobody is banned through it.')$C_RESET"
    echo
    ui_print "$(t '%s (empty = back)' "$(t 'Address to unban (number or IP)')"): 1"
    end_action
}

screen_restore() {
    top restore
    ui_crumbs "$(t 'Backup / restore')" "$(t 'Restore a backup')"
    echo
    ui_print "   1) seedtunnel-vps-1234-20261110-211004.tar.gz.enc"
    ui_print "      ${C_GREY}2026-11-10 21:10 · $(human_size 13312) · /home/ubuntu$C_RESET"
    ui_print "   2) seedtunnel-vps-1234-20261108-034100-auto.tar.gz.enc"
    ui_print "      ${C_GREY}2026-11-08 03:41 · $(human_size 12288) · /var/backups/seedtunnel$C_RESET"
    echo
    ui_print "$(t '%s (empty = back)' "$(t 'Backup to restore (number, or path of a file)')"): 1"
    end_action
}

# What the terminal can show: colors, width, characters
screen_terminal() {
    local colors key
    top terminal
    ui_crumbs "$(pv 'Terminal check' 'Vérification du terminal')"
    echo
    case $UI_COLORS in
        256 | 8) colors=$UI_COLORS ;;
        *) colors=$(pv 'none (NO_COLOR, or not a terminal)' 'aucune (NO_COLOR, ou pas un terminal)') ;;
    esac
    ui_field_add TERM "${TERM:-?}${COLORTERM:+ · COLORTERM=$COLORTERM}"
    ui_field_add "$(pv Colors Couleurs)" "$colors"
    ui_field_add "$(pv Width Largeur)" "$(pv "$UI_WIDTH columns used" "$UI_WIDTH colonnes utilisées")"
    ui_field_add "$(pv Language Langue)" "$APP_LANG"
    ui_fields_show
    echo
    ui_key 1
    key=$UI_KEY
    ui_print "  $C_BRAND● $(pv pink rose)$C_RESET   $C_GREEN● $(pv green vert)$C_RESET   $C_YELLOW● $(pv yellow jaune)$C_RESET   $C_RED● $(pv red rouge)$C_RESET   $C_GREY○ $(pv grey gris)$C_RESET   ${C_CYAN}cyan$C_RESET   $key $(pv key touche)   ${C_BADGE} v$APP_VERSION $C_RESET"
    echo
    ui_print "  $(pv 'Each of these characters must look right (no square, no « ? »):' "Chacun de ces caractères doit s'afficher (ni carré, ni « ? ») :")"
    ui_print "    ● ○ ✔ ✘ ! › · … ↵ ─ │ ┌ ┐ └ ┘ ├ ┤ ═ é è à ç « »"
    end_action
}

usage() {
    sed -n '/^#  Usage/,/^# ====/p' "${BASH_SOURCE[0]}" | sed '$d; s/^#  \{0,1\}//'
}

while (($#)); do
    case $1 in
        --fr) LANGUAGE=fr ;;
        --en) LANGUAGE=en ;;
        --no-color) COLORS=off ;;
        --color) COLORS=on ;;
        --columns)
            [[ ${2-} =~ ^[0-9]+$ ]] || {
                usage >&2
                exit 2
            }
            UI_COLUMNS=$2
            shift
            ;;
        --all) ALL=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

i18n_load "${LANGUAGE:-$(i18n_detect)}"
colors_init "$COLORS"

if ((ALL)); then
    INTERACTIVE=0
    screen_home
    if [[ -z ${UI_COLUMNS-} ]]; then screen_home_narrow; fi
    screen_vpn
    screen_clients
    screen_dns
    screen_add
    screen_danger
    screen_seedbox
    screen_bans
    screen_restore
    screen_terminal
    exit 0
fi

[[ -t 0 ]] || die 'This action is interactive: run it from a terminal, or use --all.'
INTERACTIVE=1
ui_screen
printf '\n  %s%s%s\n\n' "$C_BOLD" "$(pv "Preview of the interface of seedtunnel $APP_VERSION" "Aperçu de l'interface de seedtunnel $APP_VERSION")" "$C_RESET"
ui_print "  $(pv 'Example screens, with example data: nothing is changed on this server.' "Des écrans d'exemple, avec des données d'exemple : rien n'est modifié sur ce serveur.")"
ui_print "  $(pv 'Enter: next screen · Q: quit' 'Entrée : écran suivant · Q : quitter')"
echo
IFS= read -r -p "  $(pv 'Press Enter to start…' 'Appuyez sur Entrée pour commencer…') " CHOICE || exit 130
for screen in screen_home screen_home_narrow screen_vpn screen_clients screen_dns screen_add screen_danger screen_seedbox screen_bans screen_restore screen_terminal; do
    if [[ $screen == screen_home_narrow && -n ${UI_COLUMNS-} ]]; then continue; fi
    "$screen" || break
done
echo
say 'See you soon!'
