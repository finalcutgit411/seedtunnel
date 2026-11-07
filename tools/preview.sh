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

trap 'on_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]:-}"' ERR

ALL=0
COLORS=""
LANGUAGE=""
SCREENS=0
CHOICE=""

# pv ENGLISH FRENCH — example texts of the preview (the texts of the real menus
# go through t and lang/fr.txt)
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
    ui_status_add ok VPN "$(pv running 'en marche')" "$(pv '2 clients connected' '2 clients connectés')"
    ui_status_add ok Seedbox "$(pv running 'en marche')"
    ui_status_add ok "$(pv Firewall Pare-feu)" "$(pv on actif)"
    ui_status_add info "$(pv Disk Disque)" "62 %" "$(pv '68 GB free' '68 Go libres')"
    ui_status_add ok "$(pv Backup Sauvegarde)" "$(pv recent 'à jour')" \
        "$(pv 'last backup 3 days ago' 'dernière sauvegarde il y a 3 jours')" "$(pv '3 days ago' 'il y a 3 jours')"
    ui_status_show
    echo
    ui_menu_add 1 "$(pv 'Manage the VPN' 'Gérer le VPN')"
    ui_menu_add 2 "$(pv 'Manage the seedbox' 'Gérer la seedbox')"
    ui_menu_add 3 "$(pv 'Firewall' 'Pare-feu')"
    ui_menu_add 4 "$(pv 'Diagnostics' 'Diagnostics')"
    ui_menu_gap
    ui_menu_add 5 "$(pv 'Backup / restore' 'Sauvegarde / restauration')"
    ui_menu_add 6 "$(pv 'Update seedtunnel' 'Mettre à jour SeedTunnel')"
    ui_menu_add 7 "$(pv 'Restart the server' 'Redémarrer le serveur')"
    ui_menu_gap
    ui_menu_add L 'Language / Langue'
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
    ui_field_add "$(pv State État)" "$C_GREEN● $(pv running 'en marche')$C_RESET"
    ui_field_add "$(pv Address Adresse)" "${C_CYAN}203.0.113.10:51820$C_RESET (UDP)"
    ui_field_add Clients "$(pv '3 (2 connected right now)' '3 (2 connectés en ce moment)')"
    ui_fields_show
    echo
    ui_menu_add 1 "$(pv 'Add a client' 'Ajouter un client')"
    ui_menu_add 2 "$(pv 'Show a client (QR code, file)' 'Afficher un client (QR code, fichier)')"
    ui_menu_add 3 "$(pv 'Download link for a client (one time only)' 'Lien de téléchargement pour un client (une seule fois)')"
    ui_menu_add 4 "$(pv 'Revoke a client' 'Révoquer un client')"
    ui_menu_add 5 "$(pv 'Clients and connections' 'Clients et connexions')"
    ui_menu_gap
    ui_menu_add 6 "$(pv 'Change the settings (address, port, DNS)' 'Modifier les réglages (adresse, port, DNS)')"
    ui_menu_add 7 "$(pv 'Restart the VPN' 'Redémarrer le VPN')"
    ui_menu_add 8 "$(pv 'Remove the VPN' 'Supprimer le VPN')"
    ui_menu_show
    echo
    end_menu back
}

screen_clients() {
    top clients
    ui_crumbs VPN "$(pv 'Clients and connections' 'Clients et connexions')"
    echo
    ui_table \
        "$(pv $'CLIENT\tIP\tPORT\tRECEIVED / SENT\tLAST CONNECTION' $'CLIENT\tIP\tPORT\tREÇU / ENVOYÉ\tDERNIÈRE CONNEXION')" \
        "laptop"$'\t'"10.8.0.2"$'\t'"60001"$'\t'"$(pv '1.2GB / 340MB' '1.2Go / 340Mo')"$'\t'"$C_GREEN● $(pv connected connecté)$C_RESET (12 s)" \
        "phone"$'\t'"10.8.0.3"$'\t'"60002"$'\t'"$(pv '88MB / 12MB' '88Mo / 12Mo')"$'\t'"$(pv '2 h ago' 'il y a 2 h')" \
        "tablet"$'\t'"10.8.0.4"$'\t'"60003"$'\t'"$(pv '0B / 0B' '0o / 0o')"$'\t'"$C_GREY$(pv never jamais)$C_RESET"
    end_action
}

screen_add() {
    top add
    ui_crumbs VPN "$(pv 'Add a client' 'Ajouter un client')"
    echo
    ui_print "  $(pv 'Name of the client (empty = back): phone2' 'Nom du client (vide = retour) : phone2')"
    echo
    ui_print "  $(pv 'Applying the configuration' 'Application de la configuration')… $C_GREEN$(t 'ok')$C_RESET"
    ui_print "  $(pv 'Saving the rules' 'Enregistrement des règles')… $C_GREEN$(t 'ok')$C_RESET"
    echo
    ui_box ok "$(pv 'Client « phone2 » created' 'Client « phone2 » créé')" \
        "$(pv 'VPN address 10.8.0.5 · open port 60004' 'Adresse VPN 10.8.0.5 · port ouvert 60004')" \
        "$(pv 'File:' 'Fichier :') $C_CYAN/etc/seedtunnel/vpn/clients/phone2.conf$C_RESET" \
        "$(pv 'Next screen: its QR code, to scan with the phone.' 'Écran suivant : son QR code, à scanner avec le téléphone.')"
    end_action
}

screen_danger() {
    local question
    top danger
    ui_crumbs VPN "$(pv 'Revoke a client' 'Révoquer un client')"
    echo
    ui_box bad "$(pv 'Revoke « laptop »' 'Révoquer « laptop »')" \
        "$(pv 'This device will no longer be able to connect to the VPN.' 'Cet appareil ne pourra plus se connecter au VPN.')" \
        "$(pv 'Its file and its QR code stop working: this cannot be undone.' "Son fichier et son QR code ne marcheront plus : c'est définitif.")"
    echo
    question="$C_RED$(pv 'Revoke « laptop » for good?' 'Révoquer définitivement « laptop » ?')$C_RESET $(t '[y/N]')"
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
    top seedbox
    ui_crumbs Seedbox
    echo
    ui_field_add "$(pv 'Web interface' 'Interface web')" "${C_CYAN}https://seed.example.net/$C_RESET"
    ui_field_add "$(pv Certificate Certificat)" "Let's Encrypt"
    ui_field_add SFTP "neil@seed.example.net · $(pv '68 GB free' '68 Go libres')"
    ui_field_add Services "transmission $C_GREEN●$C_RESET  nginx $C_GREEN●$C_RESET  fail2ban $C_GREEN●$C_RESET"
    ui_fields_show
    echo
    ui_menu_add 1 "$(pv 'Change the user or the password' "Changer l'utilisateur ou le mot de passe")"
    ui_menu_add 2 "$(pv 'Domain name and HTTPS certificate' 'Nom de domaine et certificat HTTPS')"
    ui_menu_add 3 "$(pv 'SSH keys for SFTP' 'Clés SSH pour SFTP')"
    ui_menu_add 4 "$(pv 'SFTP connection: settings for WinSCP and FileZilla' 'Connexion SFTP : réglages pour WinSCP et FileZilla')"
    ui_menu_add 5 "$(pv 'Banned IP addresses (fail2ban)' 'Adresses IP bannies (fail2ban)')"
    ui_menu_gap
    ui_menu_add 6 "$(pv 'Restart the services' 'Redémarrer les services')"
    ui_menu_add 7 "$(pv 'Remove the seedbox' 'Supprimer la seedbox')"
    ui_menu_show
    echo
    end_menu back
}

# What the terminal can show: colors, width, characters
screen_terminal() {
    local colors key
    top terminal
    ui_crumbs "$(pv 'Terminal check' 'Vérification du terminal')"
    echo
    case $UI_COLORS in
        256) colors=$(pv '256 (exact mauve)' '256 (mauve exact)') ;;
        8) colors=$(pv '8 (violet shown as plain magenta)' '8 (violet affiché en magenta simple)') ;;
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
    ui_print "  $C_BRAND● $(pv violet violet)$C_RESET   $C_GREEN● $(pv green vert)$C_RESET   $C_YELLOW● $(pv yellow jaune)$C_RESET   $C_RED● $(pv red rouge)$C_RESET   $C_GREY○ $(pv grey gris)$C_RESET   ${C_CYAN}cyan$C_RESET   $key $(pv key touche)"
    echo
    ui_print "  $(pv 'Each of these characters must look right (no square, no « ? »):' "Chacun de ces caractères doit s'afficher (ni carré, ni « ? ») :")"
    ui_print "    ● ○ ✔ ✘ ! › · … ↵ ─ │ ┌ ┐ └ ┘ ├ ┤ ═ é è à ç « »"
    if ((UI_COLORS == 8)); then
        echo
        ui_box info "$(pv 'Tip for PuTTY' 'Astuce pour PuTTY')" \
            "$(pv 'For the exact mauve: Connection → Data → Terminal-type string: xterm-256color, then Session → Save, and reconnect.' 'Pour le mauve exact : Connection → Data → « Terminal-type string » : xterm-256color, puis Session → Save, et reconnectez-vous.')"
    fi
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
    screen_add
    screen_danger
    screen_seedbox
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
for screen in screen_home screen_home_narrow screen_vpn screen_clients screen_add screen_danger screen_seedbox screen_terminal; do
    if [[ $screen == screen_home_narrow && -n ${UI_COLUMNS-} ]]; then continue; fi
    "$screen" || break
done
echo
say 'See you soon!'
