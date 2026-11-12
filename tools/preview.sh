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
# SSH port of the examples (the menus ask sshd)
ssh_first_port() { echo 22; }
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

# end_keys KEY TEXT… — the keys at the bottom of a screen of an action (B, Q…)
end_keys() {
    if ((ALL)); then
        ui_footer "$@"
        printf '%s\n' "$UI_PROMPT"
        return 0
    fi
    ui_ask_choice CHOICE "$@"
    [[ ${CHOICE,,} != q ]]
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
    top_bare "$1"
    ui_header
    ui_rule
}

# A screen without the header (the QR code alone)
top_bare() {
    SCREENS=$((SCREENS + 1))
    if ((ALL)); then printf '\n=== %s ===\n' "$1"; fi
    ui_screen
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

# The home screen with the weekly backup off, and a backup made by hand: the
# block Backup in yellow, « manual »
screen_home_manual() {
    top home-manual
    ui_status_add ok VPN "$(t 'running')" "$(t '%s of %s clients connected' 2 3)"
    ui_status_add ok Seedbox "$(t 'running')"
    ui_status_add ok "$(t 'Firewall')" "$(t 'on')"
    ui_status_add info "$(t 'Disk')" "$(t '%s%%' 62)" "$(t '%s free' "$(human_size_spaced "$EXAMPLE_FREE")")"
    ui_status_add warn "$(t 'Backup')" "$(t 'manual')" "$(t 'last backup %s' "$(days_ago 3)") · $(t 'weekly backup off')" "$(days_ago 3)"
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
    ui_field_add "$(t 'In use')" "Quad9 · 9.9.9.9, 149.112.112.112"
    ui_fields_show
    echo
    ui_print "$(t 'DNS servers used by the VPN clients:')"
    vpn_dns_choices 1
    echo
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
    echo
    example_client vpn_client_card phone2 ok "$(t 'Client "%s" created' phone2)"
    end_next
}

# example_client COMMAND [ARGUMENTS…] — COMMAND run with the client of the
# examples, phone2, in a folder of its own (its file made as in the menu,
# vpn_generate_client_conf); its path shown as on a server
example_client() {
    local dir
    dir=$(mktemp -d)
    (
        VPN_STATE_DIR=$dir
        VPN_CLIENTS_DIR=$dir/clients
        mkdir "$VPN_CLIENTS_DIR"
        echo 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=' >"$dir/server.pub"
        printf '%s\n' CLIENT_NUMBER=4 CLIENT_PUBLIC_KEY=Hrl5Wv0hrZ0n3PB0Uc6nGcqIhAb8eOS2t8Wf8V9tS0E= \
            CLIENT_PRESHARED_KEY=/UwcSPg38hW/D9Y3tcS1FOV0K1wuURMbS/sesJEP5ak= \
            CLIENT_PRIVATE_KEY=yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk= >"$VPN_CLIENTS_DIR/phone2.env"
        vpn_generate_client_conf phone2 >"$VPN_CLIENTS_DIR/phone2.conf"
        "$@"
    ) | sed "s|$dir/clients|/etc/seedtunnel/vpn/clients|g"
    rm -rf "$dir"
}

# The QR code of the client of the examples, as in the menu (vpn_qr_text, the
# same margin); its lines are cut to the width of the screen (a terminal would
# wrap them). Without qrencode, a note.
example_qr() {
    local type=utf8
    if ! command -v qrencode >/dev/null; then
        ui_print "  $C_GREY$(pv '(QR code: qrencode is not installed here)' "(QR code : qrencode n'est pas installé ici)")$C_RESET"
        return 0
    fi
    if [[ -n $C_RESET ]]; then type=ansiutf8; fi
    example_qr_print() { vpn_qr_text "$VPN_CLIENTS_DIR/phone2.conf" | qrencode -t "$1" -m "$VPN_QR_MARGIN"; }
    example_client example_qr_print "$type" | print_lines
}

# After « Add a client » (vpn_show_client): the QR code alone on the screen,
# the key to go on right under it
screen_client_qr() {
    top_bare client-qr
    example_qr
    if ((ALL)); then
        ui_print "  $C_GREY$(t 'Enter ↵ continue · Q quit')$C_RESET"
        return 0
    fi
    ui_pause next tight
}

# Then what to do with it (vpn_client_screen)
screen_client() {
    local name=phone2 port=60004 VPN_CLIENTS_DIR=/etc/seedtunnel/vpn/clients
    top client
    ui_crumbs VPN "$(t 'Client "%s"' "$name")"
    echo
    text vpn_client_help | ui_text | print_lines
    echo
    ui_menu_add 1 "$(t 'Show the file (to copy and paste)')"
    ui_menu_add 2 "$(t 'One-time download link for the file')"
    ui_menu_show
    echo
    end_keys b "$(t 'Back')" q "$(t 'Quit')"
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
    ui_field_add "$(t 'Address')" "$VPN_PUBLIC_ADDRESS"
    ui_field_add Port "51820 → ${C_BOLD}51821/udp$C_RESET"
    ui_field_add DNS "Quad9 · $VPN_DNS"
    ui_field_add "$(t 'Way out')" "$(t 'interface %s' eth0)"
    ui_box_fields info "$(t 'Summary')"
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
    ui_menu_add 4 "$(t 'SFTP connection (WinSCP, FileZilla)')"
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
    seedbox_login_card 2>&1 | print_lines
    end_action
}

# Seedbox › SFTP connection (seedbox_sftp_screen), keys only
screen_sftp() {
    top sftp
    ui_crumbs Seedbox "$(t 'SFTP connection (WinSCP, FileZilla)')"
    echo
    seedbox_sftp_card 22 "$EXAMPLE_FINGERPRINT" " $(t '(SSH key only)')"
    echo
    ui_paragraph "$(t 'Profiles to import (one-time links):')"
    ui_menu_add 1 "$(t 'WinSCP profile')"
    ui_menu_add 2 "$(t 'FileZilla profile')"
    ui_menu_show
    echo
    sftp_key_choices 3 4
    echo
    end_keys b "$(t 'Back')" q "$(t 'Quit')"
}

# Seedbox › SSH keys for SFTP (sftp_keys_menu), one key, keys only
screen_keys() {
    top keys
    ui_crumbs Seedbox "$(t 'SSH keys for SFTP')"
    echo
    INTERACTIVE=1 sftp_key_line 1 "256 SHA256:Hp3cC5YyhRZmLxvU4Lw0dCq9yb6tJ8Sg2kPpd1ZfQ7c seedtunnel-lancelot-20261112-085500 (ED25519)"
    echo
    ui_field_add "$(t 'SFTP password')" "$C_GREEN● $(t 'refused (keys only)')$C_RESET"
    ui_fields_show
    echo
    sftp_key_choices 1 2
    echo
    ui_menu_add 3 "$(t 'Remove a key')"
    ui_menu_add 4 "$(t 'Allow / refuse the password in SFTP')"
    ui_menu_show
    echo
    end_menu back
}

# « I already have a key » (sftp_key_add_screen): the question
screen_key_add() {
    top key-add
    ui_crumbs Seedbox "$(t 'Add my public key')"
    echo
    ui_paragraph "$(t 'Paste the public key: one line, which starts with ssh-ed25519 or ssh-rsa. Never paste the private key.')"
    ui_paragraph "$(t 'Your key is a .ppk file of PuTTY? Open it in PuTTYgen: the public key is in the frame at the top.')"
    echo
    ui_print "$(t '%s (empty = back)' "$(t 'Public key')"): "
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
    # as backup_status_fields shows them
    ui_field_add "$(t 'Weekly')" "$C_GREEN● $(t 'turned on')$C_RESET · $C_GREY$(t 'the last %s are kept' "$BACKUP_KEEP")$C_RESET"
    ui_field_add "$(t 'Latest')" "2026-11-08 03:41 $C_GREY($(days_ago 3))$C_RESET"
    ui_field_add "$(t 'On the server')" "$(t '%s in %s' 4 "$C_CYAN$BACKUP_DIR$C_RESET")"
    ui_field_add "$(t 'Downloaded')" "$(days_ago 3)"
    ui_fields_show
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
    # as backup_auto_enable shows it
    ui_field_add "$(t 'When')" "$(t 'every week, by itself (encrypted)')"
    ui_field_add "$(t 'Kept')" "$(t 'the last %s, in %s' "$BACKUP_KEEP" "$C_CYAN$BACKUP_DIR$C_RESET")"
    ui_field_add Passphrase "$(t 'saved on the server (root only), so that it runs alone: write it down somewhere else too')"
    ui_box_fields info "$(t 'Weekly backup')"
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
    # as backup_pick_file shows them
    ui_table "#"$'\t'"$(t 'DATE')"$'\t'"$(t 'SIZE')"$'\t'"$(t 'KIND')"$'\t'"$(t 'FOLDER')" \
        "1"$'\t'"2026-11-10 21:10"$'\t'"$(human_size 13312)"$'\t'"$(t 'copied')"$'\t'"/home/ubuntu" \
        "2"$'\t'"2026-11-09 18:22"$'\t'"$(human_size 12800)"$'\t'"$(t 'by hand')"$'\t'"$BACKUP_DIR" \
        "3"$'\t'"2026-11-08 03:41"$'\t'"$(human_size 12288)"$'\t'"$(t 'weekly')"$'\t'"$BACKUP_DIR"
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
    screen_home_manual
    screen_vpn
    screen_clients
    screen_dns
    screen_vpn_address
    screen_add
    screen_client_qr
    screen_client
    screen_danger
    screen_seedbox
    screen_credentials
    screen_sftp
    screen_keys
    screen_key_add
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
for screen in screen_home screen_home_narrow screen_home_manual screen_vpn screen_clients screen_dns screen_vpn_address screen_add \
    screen_client_qr screen_client screen_danger screen_seedbox screen_credentials screen_sftp screen_keys screen_key_add screen_bans screen_backup screen_weekly screen_restore screen_terminal; do
    if [[ $screen == screen_home_narrow && -n ${UI_COLUMNS-} ]]; then continue; fi
    "$screen" || break
done
echo
say 'See you soon!'
