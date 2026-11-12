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
# the texts of the screens of the seedbox and of the backups (lang/), and the
# file of a client (its QR code): the same as in the menus
# shellcheck source=lib/seedbox.sh
. "$APP_DIR/lib/seedbox.sh"
# shellcheck source=lib/backup.sh
. "$APP_DIR/lib/backup.sh"

trap 'on_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]:-}"' ERR

ALL=0
COLORS=""
LANGUAGE=""
SCREENS=0
CHOICE=""

# Free space of the examples (68 GB)
EXAMPLE_FREE=73014444032

# The server of the examples, read by the texts of lang/ (text …)
# shellcheck disable=SC2034
{
    VPN_PUBLIC_ADDRESS=203.0.113.10
    VPN_PORT=51820
    VPN_DNS="9.9.9.9, 149.112.112.112"
    SEEDBOX_DOMAIN=seed.example.net
    SEEDBOX_USER=lancelot
    SEEDBOX_CERTIFICATE=letsencrypt
}
# Key of the SSH server of the examples: as ssh-keygen shows it, and in the
# address for WinSCP (host_key_fingerprint, host_key_fingerprint_url)
EXAMPLE_FINGERPRINT="SHA256:gAp02kYYmtWjmhPTLe83f2mfoeAcy+//GMfI045u0U0 ED25519"
EXAMPLE_FINGERPRINT_URL="ssh-ed25519-gAp02kYYmtWjmhPTLe83f2mfoeAcy-__GMfI045u0U0="

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

# The same, when another screen follows (pause_next)
end_next() {
    if ((ALL)); then
        echo
        ui_print "  $C_GREY$(t 'Enter ↵ continue · Q quit')$C_RESET"
        return 0
    fi
    ui_pause next
}

# print_lines — the lines read on the standard input, each one cut to the
# width of the screen (a text of lang/, a QR code)
print_lines() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do ui_print "$line"; done
}

# Lines of the menus that show what is done (run), and their messages
step() { ui_print "  $(t "$1")… $C_GREEN$(t 'ok')$C_RESET"; }
said_ok() { ui_print "$C_GREEN✔$C_RESET $(t "$@")"; }
said_warn() { ui_print "$C_YELLOW!$C_RESET $(t "$@")"; }

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
    end_next
}

# The QR code of the client of the examples, made by qrencode from its file
# (vpn_generate_client_conf), as in the menu; its lines are cut to the width
# of the screen (a terminal would wrap them). Without qrencode, a note.
example_qr() {
    local dir type=utf8
    if ! command -v qrencode >/dev/null; then
        ui_print "  $C_GREY$(pv '(QR code: qrencode is not installed here)' "(QR code : qrencode n'est pas installé ici)")$C_RESET"
        return 0
    fi
    if [[ -n $C_RESET ]]; then type=ansiutf8; fi
    dir=$(mktemp -d)
    (
        VPN_STATE_DIR=$dir
        VPN_CLIENTS_DIR=$dir/clients
        mkdir "$VPN_CLIENTS_DIR"
        echo 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=' >"$dir/server.pub"
        cat >"$VPN_CLIENTS_DIR/phone2.env" <<'EOF'
CLIENT_NUMBER=4
CLIENT_PUBLIC_KEY=Hrl5Wv0hrZ0n3PB0Uc6nGcqIhAb8eOS2t8Wf8V9tS0E=
CLIENT_PRESHARED_KEY=/UwcSPg38hW/D9Y3tcS1FOV0K1wuURMbS/sesJEP5ak=
CLIENT_PRIVATE_KEY=yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
EOF
        vpn_generate_client_conf phone2 | qrencode -t "$type"
    ) | print_lines
    rm -rf "$dir"
}

# The screen that follows « Add a client » (vpn_show_client)
screen_client() {
    local name=phone2 port=60004
    top client
    ui_crumbs VPN "$(t 'Client "%s"' "$name")"
    echo
    example_qr
    echo
    text vpn_client_help | print_lines
    echo
    ui_print "$(t 'Show the content of the file (to copy and paste)?') $(t '[y/N]')"
    end_action
}

# VPN › Change the address or the port (vpn_change_settings), a new port
screen_vpn_address() {
    top vpn-address
    ui_crumbs VPN "$(t 'Change the address or the port')"
    echo
    said_warn 'After a change, every client will have to import its configuration again.'
    echo
    ui_print "$(t '%s (empty = back)' "$(t 'Public address of the server (IP or domain name)')"): $VPN_PUBLIC_ADDRESS"
    ui_print "$(t '%s (empty = back)' "$(t 'UDP port of the VPN')"): 51821"
    echo
    ui_print "$(t 'Summary:')"
    ui_print "$(t '  Address : %s' "$VPN_PUBLIC_ADDRESS")"
    ui_print "$(t '  Port    : %s/udp' 51821)"
    ui_print "$(t '  DNS     : %s' "Quad9 · $VPN_DNS")"
    ui_print "$(t '  Out     : interface %s' eth0)"
    echo
    said_warn 'New port: the VPN restarts and every client is disconnected until it imports its new configuration.'
    echo
    ui_print "$(t 'Is that right?') $(t '[Y/n]')"
    step 'Updating the firewall'
    step 'Restarting the VPN (new port)'
    said_ok 'Settings saved. Show the clients again to get their new QR codes.'
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

# Seedbox › Change the user or the password (seedbox_change_credentials), the
# password generated
screen_credentials() {
    local port=22 SEEDBOX_NEW_PASSWORD="dGgNV5GVohRrW1ClQuk4"
    top credentials
    ui_crumbs Seedbox "$(t 'Change the user or the password')"
    echo
    ui_print "$(t '%s (empty = back)' "$(t 'User name (web and SFTP)')"): $SEEDBOX_USER"
    ui_print "$(t 'Password (leave empty to generate one):')"
    ui_print "$(t 'Generated password: %s  ← write it down' "$C_BOLD$SEEDBOX_NEW_PASSWORD$C_RESET")"
    echo
    ui_print "$(t 'Save the user %s with this password?' "$SEEDBOX_USER") $(t '[Y/n]')"
    echo
    step 'Stopping Transmission'
    step 'Starting Transmission'
    echo
    said_ok 'Login test on the web interface: passed'
    echo
    text seedbox_summary | print_lines
    end_action
}

# Seedbox › SFTP connection (seedbox_sftp_config), keys only
screen_sftp() {
    local url="sftp://$SEEDBOX_USER;fingerprint=$EXAMPLE_FINGERPRINT_URL@$SEEDBOX_DOMAIN:22/"
    top sftp
    ui_crumbs Seedbox "$(t 'SFTP connection: settings for WinSCP and FileZilla')"
    echo
    ui_print "$(t '  Protocol    : SFTP')"
    ui_print "$(t '  Host        : %s' "$SEEDBOX_DOMAIN")"
    ui_print "$(t '  Port        : %s' 22)"
    ui_print "$(t '  User        : %s' "$SEEDBOX_USER $(t '(SSH key only)')")"
    ui_print "$(t '  Fingerprint : %s' "$EXAMPLE_FINGERPRINT")"
    echo
    text sftp_config_help | print_lines
    echo
    ui_print "$(t 'Also create a link to a file to import into FileZilla?') $(t '[y/N]')"
    ui_print "$(t 'Create an SSH key for WinSCP / FileZilla (connection without a password)?') $(t '[y/N]')"
    end_action
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

# Backup / restore (backup_menu), the weekly backup on
screen_backup() {
    top backup
    ui_crumbs "$(t 'Backup / restore')"
    echo
    ui_print "$(t 'Weekly backup: on (the last %s are kept in %s)' "$BACKUP_KEEP" "$BACKUP_DIR")"
    ui_print "$(t '  Last one: %s' '2026-11-08 03:41')"
    ui_print "$(t 'Last download of a backup started: %s' "$(days_ago 3)")"
    echo
    ui_menu_add 1 "$(t 'Create an encrypted backup now')"
    ui_menu_add 2 "$(t 'Download the latest backup (one-time link)')"
    ui_menu_add 3 "$(t 'Turn the weekly backup on / off')"
    ui_menu_add 4 "$(t 'Restore a backup')"
    ui_menu_show
    echo
    end_menu back
}

# Backup / restore › Weekly backup, turned on (backup_auto_enable), with
# backups already made
screen_weekly() {
    top weekly
    ui_crumbs "$(t 'Backup / restore')" "$(t 'Weekly backup')"
    echo
    text backup_auto_help | print_lines
    echo
    said_warn 'The backups already made keep the passphrase they were made with: the new one only applies to the next ones.'
    echo
    ui_print "$(t 'Passphrase of the backup (empty = back):')"
    ui_print "$(t 'Type it again:')"
    step 'Reloading systemd'
    step 'Enabling the weekly backup'
    said_ok 'Weekly backup on: the last %s are kept in %s.' "$BACKUP_KEEP" "$BACKUP_DIR"
    said_warn 'Write the passphrase down somewhere else: without it, no backup can be restored.'
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
    screen_vpn_address
    screen_add
    screen_client
    screen_danger
    screen_seedbox
    screen_credentials
    screen_sftp
    screen_bans
    screen_backup
    screen_weekly
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
for screen in screen_home screen_home_narrow screen_vpn screen_clients screen_dns screen_vpn_address screen_add screen_client \
    screen_danger screen_seedbox screen_credentials screen_sftp screen_bans screen_backup screen_weekly screen_restore screen_terminal; do
    if [[ $screen == screen_home_narrow && -n ${UI_COLUMNS-} ]]; then continue; fi
    "$screen" || break
done
echo
say 'See you soon!'
