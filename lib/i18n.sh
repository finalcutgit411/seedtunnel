#!/usr/bin/env bash
# =============================================================================
#  seedtunnel — translations (English and French)
#
#  Messages are written in English, right in the code, as printf formats:
#      ok 'Client "%s" created.' "$name"
#  In French, each format is looked up in lang/fr.txt, a plain text file in
#  which every English line ("en: …") is followed by its translation
#  ("fr: …"). A missing translation simply shows the English text.
#
#  Longer texts (help, summaries) are functions in lang/en.sh and lang/fr.sh,
#  named text_en_<name> and text_fr_<name>, and shown with:  text <name>
#
#  Language, in order of priority:
#    1. SEEDTUNNEL_LANG=en or fr in the environment;
#    2. the choice saved with « seedtunnel language » (/etc/seedtunnel/language);
#    3. the system language (LC_ALL, LC_MESSAGES, LANG): French if it starts
#       with « fr »;
#    4. English.
# =============================================================================

APP_LANG=en
APP_LANGUAGES=" en fr "
declare -gA TRANSLATIONS=()

is_language() { [[ -n $1 && $APP_LANGUAGES == *" $1 "* ]]; }

# Language chosen by the environment, the saved choice or the system
i18n_detect() {
    local saved="" system=${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}
    if is_language "${SEEDTUNNEL_LANG-}"; then
        printf '%s' "$SEEDTUNNEL_LANG"
        return 0
    fi
    if [[ -r $APP_LANG_FILE ]]; then
        IFS= read -r saved <"$APP_LANG_FILE" || true
        if is_language "$saved"; then
            printf '%s' "$saved"
            return 0
        fi
    fi
    if [[ $system == fr* ]]; then printf fr; else printf en; fi
}

# i18n_load LANGUAGE — loads the long texts and the translated messages
i18n_load() {
    local line key="" catalog
    APP_LANG=$1
    TRANSLATIONS=()
    # shellcheck source=lang/en.sh
    . "$APP_DIR/lang/en.sh"
    [[ $APP_LANG != en ]] || return 0
    # shellcheck source=/dev/null
    if [[ -r $APP_DIR/lang/$APP_LANG.sh ]]; then . "$APP_DIR/lang/$APP_LANG.sh"; fi
    catalog="$APP_DIR/lang/$APP_LANG.txt"
    [[ -r $catalog ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            "en: "*) key=${line#en: } ;;
            "$APP_LANG: "*)
                if [[ -n $key ]]; then TRANSLATIONS[$key]=${line#"$APP_LANG: "}; fi
                key=""
                ;;
        esac
    done <"$catalog"
}

i18n_init() { i18n_load "$(i18n_detect)"; }

# tr_format FORMAT → TR_FORMAT: the format in the current language, not filled
tr_format() {
    TR_FORMAT=$1
    if [[ $APP_LANG != en && -n $1 && -n ${TRANSLATIONS[$1]-} ]]; then TR_FORMAT=${TRANSLATIONS[$1]}; fi
}

# t FORMAT [ARGUMENTS…] → the message in the current language
t() {
    tr_format "$1"
    shift
    # shellcheck disable=SC2059 # the format comes from the code or from lang/
    printf -- "$TR_FORMAT" "$@"
}

# text NAME → a long text from lang/<language>.sh (English if missing)
text() {
    if declare -F "text_${APP_LANG}_$1" >/dev/null; then
        "text_${APP_LANG}_$1"
    else
        "text_en_$1"
    fi
}

# Saves the language for the next runs: written next to it, then renamed (a
# full disk never leaves a cut file). If it cannot be saved, the language
# still applies to this run.
language_save() {
    install -d -m 700 "$APP_STATE_DIR"
    if ! { printf '%s\n' "$1" >"$APP_LANG_FILE.tmp" && mv -f "$APP_LANG_FILE.tmp" "$APP_LANG_FILE"; } 2>>"$APP_LOG"; then
        rm -f "$APP_LANG_FILE.tmp"
        warn 'Cannot save the language (disk full?): it only applies to this run.'
    fi
    i18n_load "$1"
}

# language_reload — after something that may have changed the language saved
# (a restore, run in a subshell): the menus go on in it. Nothing saved (it
# could not be written): the language of this run stays. SEEDTUNNEL_LANG still
# wins.
language_reload() {
    local language
    is_language "${SEEDTUNNEL_LANG-}" && return 0
    language=$(language_saved)
    if [[ -n $language && $language != "$APP_LANG" ]]; then i18n_load "$language"; fi
}

# Language saved for this server, if it is one (empty otherwise)
language_saved() {
    local saved=""
    if [[ -r $APP_LANG_FILE ]]; then IFS= read -r saved <"$APP_LANG_FILE" || true; fi
    if is_language "$saved"; then printf '%s' "$saved"; fi
}

# First menu run without a saved choice (or with a file that holds something
# else): a first screen like the menus, in English (no language chosen yet),
# asked again until the answer is 1 (or Enter) or 2. Q leaves, nothing saved.
language_first_run() {
    local choice
    [[ -z $(language_saved) ]] || return 0
    is_language "${SEEDTUNNEL_LANG-}" && return 0
    i18n_load en
    while true; do
        ui_screen
        ui_header
        ui_rule
        echo
        ui_print "  ${C_BOLD}Welcome$C_RESET"
        echo
        ui_print "  Choose your language"
        echo
        ui_menu_add 1 English
        ui_menu_add 2 Français
        ui_menu_show
        echo
        ui_print "  ${C_GREY}Enter ↵ English · later from the menu: [L] Language / Langue$C_RESET"
        ui_ask_choice choice q Quit
        case ${choice,,} in
            "" | 1)
                language_save en
                return 0
                ;;
            2)
                language_save fr
                return 0
                ;;
            q) ui_quit ;;
        esac
    done
}

# seedtunnel language [en|fr]
language_cli() {
    case ${1-} in
        "") say 'Language: %s   (change it with: seedtunnel language en|fr)' "$APP_LANG" ;;
        en | fr)
            language_save "$1"
            ok 'Language: %s.' "$(t 'English')"
            ;;
        *) die 'Usage: seedtunnel language en|fr' ;;
    esac
}

# From the menu (not in a subshell: the choice must stay): an empty answer or
# B goes back
language_menu() {
    local choice
    while true; do
        ui_top 'Language / Langue'
        ui_menu_add 1 English
        ui_menu_add 2 Français
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1)
                language_save en
                return 0
                ;;
            2)
                language_save fr
                return 0
                ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}
