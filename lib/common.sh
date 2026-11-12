#!/usr/bin/env bash
# =============================================================================
#  seedtunnel — shared library
#  Output, input, log, configuration file, system checks, apt, network.
#  Loaded by seedtunnel.sh: this file does nothing on its own.
# =============================================================================

APP_NAME="seedtunnel"
APP_VERSION="0.9.0"
# GitHub repository used by « seedtunnel update » (owner/project)
APP_REPO="finalcutgit411/seedtunnel"
# Server state and secrets (readable by root only)
APP_STATE_DIR="/etc/seedtunnel"
APP_LANG_FILE="$APP_STATE_DIR/language"
# Detailed output of every command the script runs
APP_LOG="/var/log/seedtunnel.log"
# Prevents two copies of the script from changing the server at the same time
APP_LOCK="/run/seedtunnel.lock"
# System of the server, read by os_read (the file is a variable for the tests)
APP_OS_RELEASE="/etc/os-release"
APP_OS_ID=""
APP_OS_VERSION=""
APP_OS_DESCRIPTION=""
APP_APT_UPDATED=0

# Command line options (set by seedtunnel.sh)
INTERACTIVE=0
OPT_YES=0
OPT_CONFIG_FILE=""
OPT_STAGING=0
OPT_OUTPUT_FILE=""
OPT_PASSPHRASE_FILE=""
OPT_PURGE_DATA=0
OPT_QR=0
OPT_LINK=0
OPT_NEW_USER=""

# --- Colors -------------------------------------------------------------------------
# Is the output a terminal? (a function, so that the tests can say yes)
stdout_is_terminal() { [[ -t 1 ]]; }

# colors_init on|off|auto — auto (or empty): on when the output is a terminal,
# unless NO_COLOR is set (https://no-color.org) or the terminal is « dumb ».
# Pink is the color of seedtunnel (bright magenta), on every terminal: the
# same pink with 256 colors (color 207) as with 8 (PuTTY says « xterm », 8
# colors, and shows bold magenta in bright pink). 256 colors only bring a
# finer grey.
colors_init() {
    local mode=${1:-auto}
    if [[ $mode == auto ]]; then
        if stdout_is_terminal && [[ -z ${NO_COLOR-} && ${TERM-} != dumb ]]; then mode=on; else mode=off; fi
    fi
    C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_DIM="" C_RESET=""
    C_BRAND="" C_BADGE="" C_CYAN="" C_GREY=""
    UI_COLORS=0
    [[ $mode == on ]] || return 0
    C_RED=$'\e[1;31m'
    C_GREEN=$'\e[1;32m'
    C_YELLOW=$'\e[1;33m'
    C_BLUE=$'\e[1;34m'
    C_BOLD=$'\e[1m'
    C_DIM=$'\e[2m'
    C_RESET=$'\e[0m'
    C_CYAN=$'\e[36m'
    if [[ ${TERM-} == *256color* || ${COLORTERM-} == truecolor || ${COLORTERM-} == 24bit ]]; then
        UI_COLORS=256
        C_BRAND=$'\e[1;38;5;207m'
        C_BADGE=$'\e[1;97;48;5;127m'
        C_GREY=$'\e[38;5;245m'
    else
        UI_COLORS=8
        C_BRAND=$'\e[1;35m'
        C_BADGE=$'\e[1;37;45m'
        C_GREY=$C_DIM
    fi
}
colors_init auto

# --- Output -----------------------------------------------------------------------
# Every message is a printf format written in English (see lib/i18n.sh):
#   ok 'Client "%s" created.' "$name"

# New screen of the menus: header of seedtunnel (lib/ui.sh). Nothing for the
# commands.
banner() {
    ((INTERACTIVE)) || return 0
    ui_screen
    ui_header
    ui_rule
}

say() {
    t "$@"
    printf '\n'
}
# section FORMAT [ARGUMENTS…] — title of a screen. In the menus, where we are:
# « seedtunnel › VPN › Add a client » (UI_PLACE: the menus we are in). For
# the commands, the title in capitals (not the values: names of clients…).
section() {
    local format
    tr_format "$1"
    shift
    # shellcheck disable=SC2059 # the format comes from the code or from lang/
    if ((INTERACTIVE)); then
        ui_crumbs "${UI_PLACE[@]}" "$(printf -- "$TR_FORMAT" "$@")"
        echo
    else
        format=${TR_FORMAT^^}
        format=${format//%S/%s}
        format=${format//%D/%d}
        printf '%s%s%s\n\n' "$C_BOLD" "$(printf -- "$format" "$@")" "$C_RESET"
    fi
}
ok() { printf '%s✔%s %s\n' "$C_GREEN" "$C_RESET" "$(t "$@")"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$(t "$@")" >&2; }
err() { printf '%s✘ %s%s\n' "$C_RED" "$(t "$@")" "$C_RESET" >&2; }

# Stops the script with a message.
# Careful: inside $(…) it only leaves the subshell, so avoid it there.
die() {
    err "$@"
    exit 1
}

# End of an action in the menus: « Enter ↵ back · Q quit » (Q leaves
# seedtunnel). pause_next: in the middle of a series of screens, « Enter ↵
# continue ».
pause() {
    ((INTERACTIVE)) || return 0
    if ! ui_pause; then ui_quit; fi
}

pause_next() {
    ((INTERACTIVE)) || return 0
    if ! ui_pause next; then ui_quit; fi
}

# An action that goes back without changing anything (empty answer, « no »)
# sets WENT_BACK=1 and returns 0: its caller then skips the pause. That way an
# action that changes the server is always called on its own, never in an
# « if » or before « || » or « && »: bash would ignore « set -e » inside it,
# and a step that fails would not stop the next ones.
WENT_BACK=0

# 0 → « today », 1 → « yesterday », N → « N days ago »
days_ago() {
    case $1 in
        0) t 'today' ;;
        1) t 'yesterday' ;;
        *) t '%s days ago' "$1" ;;
    esac
}

# State of a service, in color: running / stopped / missing
service_state() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        printf '%s%s%s' "$C_GREEN" "$(t 'running')" "$C_RESET"
    elif systemctl cat "$1" &>/dev/null; then
        printf '%s%s%s' "$C_RED" "$(t 'stopped')" "$C_RESET"
    else
        printf '%s%s%s' "$C_DIM" "$(t 'missing')" "$C_RESET"
    fi
}

# Short state of a service, for a line that lists several: OK / stopped /
# missing, in color. A stopped or missing service never looks « OK ».
service_state_short() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        printf '%s●%s' "$C_GREEN" "$C_RESET"
    elif systemctl cat "$1" &>/dev/null; then
        printf '%s● %s%s' "$C_RED" "$(t 'stopped')" "$C_RESET"
    else
        printf '%s● %s%s' "$C_RED" "$(t 'missing')" "$C_RESET"
    fi
}

# unit_ensure_on "Description" UNIT — the systemd unit is enabled at boot and
# running (one that was turned off by hand, or whose enabling failed, is put
# right). Nothing is done when it already is: « seedtunnel apply » then changes
# nothing. A failure stops the script with the end of the log, like « run ».
unit_ensure_on() {
    local description=$1 unit=$2
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        run "$description" systemctl enable --now "$unit"
    elif ! systemctl is-active --quiet "$unit" 2>/dev/null; then
        run "$description" systemctl start "$unit"
    fi
}

# --- Errors -----------------------------------------------------------------------
# Any command that fails without being handled ends up here (set -e + trap
# ERR): we show where, instead of carrying on in a half-done state.
# The trap of the script (also set again in the actions of the menus)
error_trap_on() { trap 'on_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]:-}"' ERR; }

# Shown once: by the script itself, or by the action of a menu in which it
# happened (see ui_action), not by the $(…) inside them.
on_error() {
    local code=$1 line=$2 command=$3 file=${4##*/}
    trap - ERR
    if ((BASH_SUBSHELL == ${UI_ACTION_LEVEL:-0})); then
        printf '\n%s✘ %s%s\n    %s\n' "$C_RED" \
            "$(t 'Unexpected error (code %s) in %s, line %s:' "$code" "${file:-?}" "$line")" \
            "$C_RESET" "$command" >&2
        printf '  %s\n' "$(t 'Detailed log: %s' "$APP_LOG")" >&2
    fi
    exit "$code"
}

# subshell_run COMMAND [ARGUMENTS…] → SUBSHELL_STATUS: COMMAND in a subshell
# where « set -e » and the error trap are in force, whatever the caller does.
# Written « ( … ) || exit 1 », or in an « if », bash would turn them off inside
# the subshell. What COMMAND changes (variables, traps) stays in the subshell.
subshell_run() {
    local errexit=0 trap_err
    if [[ $- == *e* ]]; then errexit=1; fi
    trap_err=$(trap -p ERR)
    trap - ERR
    set +e
    (
        UI_ACTION_LEVEL=$BASH_SUBSHELL
        set -e
        error_trap_on
        "$@"
    )
    SUBSHELL_STATUS=$?
    if ((errexit)); then set -e; fi
    if [[ -n $trap_err ]]; then eval "$trap_err"; fi
}

# in_subshell COMMAND [ARGUMENTS…] — the same, and if COMMAND fails, the
# caller stops with its status (its message is already on the screen)
in_subshell() {
    subshell_run "$@"
    if ((SUBSHELL_STATUS != 0)); then exit "$SUBSHELL_STATUS"; fi
}

# log_title "Description" [ARGUMENTS…] — a title in the log, in the language of
# the messages, for what is written there without « run » or « log_run »
log_title() {
    log_print '\n=== %(%F %T)T · %s\n' -1 "$(t "$@")"
}

# log_print FORMAT [ARGUMENTS…] — written to the log. A log that cannot be
# written (system disk full) never stops the script by itself.
log_print() {
    # shellcheck disable=SC2059 # the format comes from the caller
    printf "$@" >>"$APP_LOG" 2>/dev/null || true
}

# Free space (MB) under which nothing is changed: APT, the settings and the
# log need some. Without this, a full disk stopped the script on a write
# error that did not speak of the disk.
DISK_MIN_FREE_MB=100

# disk_space_check — stops before anything is changed if the disk of /, of
# the settings or of the log is (almost) full
disk_space_check() {
    local folder free mount
    for folder in / "${APP_STATE_DIR%/*}" "${APP_LOG%/*}"; do
        [[ -d $folder ]] || continue
        read -r free mount < <(df -Pm -- "$folder" 2>/dev/null | awk 'NR == 2 { print $4, $6 }') || continue
        [[ $free =~ ^[0-9]+$ ]] || continue
        if ((free < DISK_MIN_FREE_MB)); then
            die 'The system disk is full (%s MB free on %s): nothing was changed. Free some space first, for example:  apt clean; journalctl --vacuum-size=100M' \
                "$free" "${mount:-$folder}"
        fi
    done
}

# log_run "Description" COMMAND [ARGUMENTS…] — like run, but silent and never
# a failure: for what may fail without harm (stopping a service already
# stopped). Its output goes to the log under its own title, not under the one
# of the step before.
log_run() {
    local description
    description=$(t "$1")
    shift
    log_print '\n=== %(%F %T)T · %s\n$ %s\n' -1 "$description" "$*"
    "$@" >>"$APP_LOG" 2>&1 || true
}

# run "Description" COMMAND [ARGUMENTS…]
# Runs a command with its output sent to the log; prints « ok », or the end of
# the log and stops the script if it fails.
# Never pass a password as an argument: it would end up in the log.
run() {
    local description code
    description=$(t "$1")
    shift
    printf '  %s… ' "$description"
    log_print '\n=== %(%F %T)T · %s\n$ %s\n' -1 "$description" "$*"
    if "$@" >>"$APP_LOG" 2>&1; then
        printf '%s%s%s\n' "$C_GREEN" "$(t 'ok')" "$C_RESET"
    else
        code=$?
        printf '%s%s%s\n\n' "$C_RED" "$(t 'failed')" "$C_RESET"
        tail -n 15 "$APP_LOG" | sed 's/^/    /' >&2
        echo >&2
        die '"%s" failed (code %s). Full log: %s' "$description" "$code" "$APP_LOG"
    fi
}

# --- Input ------------------------------------------------------------------------
# Local variables have unique prefixes: printf -v writes into the caller's
# variable, and a local variable with the same name would hide it.

require_terminal() {
    [[ -t 0 ]] || die 'This action is interactive: run it from a terminal, or use --config.'
    INTERACTIVE=1
}

# Is the standard input a terminal? (a function, so that the tests can say yes)
stdin_is_terminal() { [[ -t 0 ]]; }

# ask_back VARIABLE "Question" [suggested value] — like ask, but an empty answer
# goes back: status 1, the variable is left alone, nothing is to be changed.
# Every question of the menus can be left this way (a suggestion is erased
# first).
ask_back() {
    local _ab_var=$1 _ab_question _ab_answer
    _ab_question=$(t '%s (empty = back)' "$(t "$2")")
    ((INTERACTIVE)) || die 'Question asked outside interactive mode: %s' "$_ab_question"
    IFS= read -r -e -i "${3-}" -p "$_ab_question: " _ab_answer || {
        echo
        exit 130
    }
    trim_spaces _ab_answer
    [[ -n $_ab_answer ]] || return 1
    printf -v "$_ab_var" '%s' "$_ab_answer"
}

# ask VARIABLE "Question" [suggested value]   (the suggestion can be edited)
ask() {
    local _ask_var=$1 _ask_question _ask_default=${3-} _ask_answer
    _ask_question=$(t "$2")
    ((INTERACTIVE)) || die 'Question asked outside interactive mode: %s' "$_ask_question"
    IFS= read -r -e -i "$_ask_default" -p "$_ask_question: " _ask_answer || {
        echo
        exit 130
    }
    trim_spaces _ask_answer
    printf -v "$_ask_var" '%s' "$_ask_answer"
}

# trim_spaces VARIABLE — without the spaces before and after: a path pasted
# with a space at the end is still found (« File not found » before)
trim_spaces() {
    local _ts_value=${!1}
    _ts_value=${_ts_value#"${_ts_value%%[![:space:]]*}"}
    _ts_value=${_ts_value%"${_ts_value##*[![:space:]]}"}
    printf -v "$1" '%s' "$_ts_value"
}

# confirm "Question" [y|n]   → status 0 if the answer is yes
# --yes counts as a confirmation; without a terminal, it is the only way.
confirm() {
    local question default=${2:-n} answer hint
    question=$(t "$1")
    if ((OPT_YES)); then return 0; fi
    [[ -t 0 ]] || die '%s → run again with --yes to confirm.' "$question"
    if [[ $default == y ]]; then hint=$(t '[Y/n]'); else hint=$(t '[y/N]'); fi
    while true; do
        IFS= read -r -p "$question $hint " answer || {
            echo
            exit 130
        }
        answer=${answer:-$default}
        case ${answer,,} in
            y | yes | o | oui) return 0 ;;
            n | no | non) return 1 ;;
        esac
    done
}

# Random password: 20 letters and digits (~119 bits)
generate_password() {
    local p
    p=$(openssl rand -base64 48)
    p=${p//[^A-Za-z0-9]/}
    printf '%s' "${p:0:20}"
}

# ask_password VARIABLE — hidden input, typed twice; empty = generated password
ask_password() {
    local _ap_var=$1 _ap_first _ap_second
    while true; do
        IFS= read -r -s -p "$(t 'Password (leave empty to generate one):') " _ap_first || {
            echo
            exit 130
        }
        echo
        if [[ -z $_ap_first ]]; then
            _ap_first=$(generate_password)
            say 'Generated password: %s  ← write it down' "$C_BOLD$_ap_first$C_RESET"
            break
        fi
        if ((${#_ap_first} < 10)); then
            warn 'At least 10 characters.'
            continue
        fi
        IFS= read -r -s -p "$(t 'Type the password again:') " _ap_second || {
            echo
            exit 130
        }
        echo
        [[ $_ap_first == "$_ap_second" ]] && break
        warn 'The two entries differ, try again.'
    done
    printf -v "$_ap_var" '%s' "$_ap_first"
}

# --- Files ------------------------------------------------------------------------

# state_file_is_safe FILE [NAMES] — can a state file be read by « . »
# (state_read) without running anything? Only the lines that state_write
# writes: comments, empty lines, NAME='' or NAME=value where the value is made
# of harmless characters, or of characters escaped with a backslash (printf
# %q), which then stand for themselves. « X=$(command) » is refused: $ and (
# are not escaped. NAMES (« VPN_PORT|VPN_DNS »): the only names allowed.
state_file_is_safe() {
    local names=${2:-[A-Za-z_][A-Za-z0-9_]*}
    ! LC_ALL=C grep -qvE "^(#.*|($names)=(''|([A-Za-z0-9_./:@,+=%-]|\\\\.)+))?$" "$1"
}

# state_write FILE VAR1 VAR2…  → writes VAR=value (escaped), mode 600
state_write() {
    local file=$1 var
    shift
    {
        printf '# %s\n' 'Written by seedtunnel — do not edit by hand'
        for var in "$@"; do printf '%s=%q\n' "$var" "${!var}"; done
    } >"$file.tmp" || die 'Cannot write %s (disk full?).' "$file"
    chmod 600 "$file.tmp"
    mv -f "$file.tmp" "$file"
}

state_read() {
    if [[ -r $1 ]]; then
        # shellcheck source=/dev/null
        . "$1"
    fi
}

# write_if_changed FILE MODE OWNER COMMAND [ARGUMENTS…]
# Runs COMMAND, which prints the wanted content, and replaces FILE only if
# this content is different: that is what lets the script run again without
# restarting anything.
# Returns 0 if FILE was changed, 1 if it was already up to date. Any failure
# (command, disk full, permissions) stops the script with a clear message and
# leaves FILE as it was: never a half-written configuration.
# A configuration written but not applied yet (the service refused it, or the
# script stopped in between) keeps a mark: the next run applies it again even
# though the file no longer changes. The mark goes once the service took it.
#   pending_set NAME · pending NAME (status 0 if waiting) · pending_clear NAME
pending_set() {
    install -d -m 700 "$APP_STATE_DIR/pending"
    : >"$APP_STATE_DIR/pending/$1"
}
pending() { [[ -e $APP_STATE_DIR/pending/$1 ]]; }
pending_clear() { rm -f "$APP_STATE_DIR/pending/$1"; }

write_if_changed() {
    local file=$1 mode=$2 owner=$3 tmp
    shift 3
    tmp=$(mktemp "$file.XXXXXX") || die 'Cannot create a temporary file next to %s.' "$file"
    if ! "$@" >"$tmp"; then
        rm -f "$tmp"
        die 'Cannot generate %s (disk full?). The file was not changed.' "$file"
    fi
    if [[ -f $file ]] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        if ! { chmod "$mode" "$file" && chown "$owner" "$file"; }; then
            die 'Cannot set the permissions of %s.' "$file"
        fi
        written_remember "$file"
        return 1
    fi
    if written_changed "$file"; then written_keep_copy "$file"; fi
    if ! { chmod "$mode" "$tmp" && chown "$owner" "$tmp" && mv -f "$tmp" "$file"; }; then
        rm -f "$tmp"
        die 'Cannot replace %s: the previous version was kept.' "$file"
    fi
    written_remember "$file"
    return 0
}

# --- Files changed by hand ----------------------------------------------------------
# The fingerprint (SHA-256) of each file written by write_if_changed is kept in
# the state. A file whose fingerprint changed since was changed by hand: before
# seedtunnel replaces it, a copy is kept and it is said. Nothing is known the
# first time (no fingerprint yet), nor after a restore or a return to an older
# version (written_forget): nothing is said then.

written_list() { printf '%s' "$APP_STATE_DIR/written.sha256"; }

# written_remember FILE — the content of FILE is now the one seedtunnel wrote
written_remember() {
    local list sum tmp
    list=$(written_list)
    [[ -d ${list%/*} ]] || return 0
    sum=$(sha256sum <"$1") || return 0
    tmp=$(mktemp "$list.XXXXXX") || return 0
    if { if [[ -f $list ]]; then awk -v file="$1" '$2 != file' "$list"; fi && printf '%s %s\n' "${sum%% *}" "$1"; } >"$tmp" \
        && chmod 600 "$tmp" && mv -f "$tmp" "$list"; then
        return 0
    fi
    rm -f "$tmp"
}

# written_changed FILE — true if FILE changed since seedtunnel wrote it
written_changed() {
    local list recorded sum
    list=$(written_list)
    [[ -f $1 && -f $list ]] || return 1
    recorded=$(awk -v file="$1" '$2 == file { print $1 }' "$list")
    [[ -n $recorded ]] || return 1
    sum=$(sha256sum <"$1") || return 1
    [[ ${sum%% *} != "$recorded" ]]
}

written_forget() { rm -f "$(written_list)"; }

# written_keep_copy FILE — a copy of FILE, changed by hand, before it is
# replaced. Readable by root only: some of these files hold secrets (keys of
# WireGuard, passwords of the web interface).
written_keep_copy() {
    local dir="$APP_STATE_DIR/changed-by-hand" copy
    copy="$dir/${1//\//_}.$(date +%Y%m%d-%H%M%S)"
    if ! { install -d -m 700 "$dir" && cp -p "$1" "$copy"; }; then
        die 'Cannot keep a copy of %s, changed by hand: it was not replaced.' "$1"
    fi
    log_title 'Changed by hand: %s, copy kept in %s' "$1" "$copy"
    warn '%s was changed by hand: seedtunnel puts its own version back, yours is kept in %s' "$1" "$copy"
}

# --- Configuration file (--config) ----------------------------------------------------
# The file is never executed: it is read line by line, and only the keys below
# are accepted. Values are stored in CONFIG_VALUE_<KEY>.
CONFIG_KEYS=" LANGUAGE VPN_PUBLIC_ADDRESS VPN_PORT VPN_DNS VPN_CLIENTS SEEDBOX_USER
 SEEDBOX_PASSWORD SEEDBOX_PASSWORD_FILE SEEDBOX_DOMAIN SEEDBOX_DATA_DIR
 SEEDBOX_LETSENCRYPT SEEDBOX_LETSENCRYPT_SERVER SEEDBOX_SSH_KEYS_FILE
 SEEDBOX_SFTP_PASSWORD FIREWALL "

# Does the file belong to root, readable by root only?
secret_file_private() {
    local owner="" mode=""
    read -r owner mode < <(stat -L -c '%u %a' -- "$1" 2>/dev/null) || true
    [[ $owner == "$EUID" && $mode == [0-7]00 ]]
}

# A file that may hold a secret must belong to root and be readable by root
# only (it is refused otherwise, before being read)
secret_file_check() {
    if ! secret_file_private "$1"; then
        die '%s may hold a secret: it must belong to root and be readable by root only:  chown root: %s && chmod 600 %s' "$1" "$1" "$1"
    fi
}

config_load() {
    local file=$1 line key value number=0
    [[ -r $file ]] || die 'Configuration file not found: %s' "$file"
    # it may hold a password
    secret_file_check "$file"
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! $line =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            die '%s, line %s: expected format KEY=value' "$file" "$number"
        fi
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        # trailing spaces and quotes around the value
        value=${value%"${value##*[![:space:]]}"}
        if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
        [[ $CONFIG_KEYS == *[[:space:]]"$key"[[:space:]]* ]] || die '%s, line %s: unknown key "%s"' "$file" "$number" "$key"
        printf -v "CONFIG_VALUE_$key" '%s' "$value"
    done <"$file"
    # language of the messages on this server, if chosen in the file
    # (SEEDTUNNEL_LANG in the environment still wins for this run)
    value=$(config_get LANGUAGE)
    if [[ -n $value ]]; then
        is_language "$value" || die '%s: LANGUAGE must be en or fr.' "$file"
        language_save "$value"
        if is_language "${SEEDTUNNEL_LANG-}"; then i18n_load "$SEEDTUNNEL_LANG"; fi
    fi
}

# config_get KEY [default] → value read from the configuration file, or the default
config_get() {
    local var="CONFIG_VALUE_$1"
    printf '%s' "${!var:-${2-}}"
}

# --- System -----------------------------------------------------------------------
# os_read → APP_OS_ID (debian, ubuntu…), APP_OS_VERSION (13, 24.04…) and
# APP_OS_DESCRIPTION (« Ubuntu 24.04.3 LTS »)
os_read() {
    [[ -r $APP_OS_RELEASE ]] || die 'Unknown system (no /etc/os-release file).'
    IFS='|' read -r APP_OS_ID APP_OS_VERSION APP_OS_DESCRIPTION < <(
        # shellcheck source=/dev/null
        . "$APP_OS_RELEASE"
        printf '%s|%s|%s\n' "${ID:-?}" "${VERSION_ID:-?}" "${PRETTY_NAME:-${NAME:-?}}"
    )
}

# os_check → stops on a system seedtunnel is not made for. Debian 11 gets its
# own message: the way up is known.
os_check() {
    os_read
    case "$APP_OS_ID $APP_OS_VERSION" in
        "debian 12" | "debian 13" | "ubuntu 24.04" | "ubuntu 26.04") return 0 ;;
        "debian 11") die 'Debian 11 has had no security updates since 31 August 2026: seedtunnel no longer supports it. Upgrade to Debian 12, then to Debian 13:  https://www.debian.org/releases/bookworm/releasenotes' ;;
    esac
    die 'Supported systems: Debian 12/13, Ubuntu 24.04/26.04 — detected: %s.' "$APP_OS_DESCRIPTION"
}

check_system() {
    [[ $EUID -eq 0 ]] || die 'This script must run as root:  sudo %s' "$0"
    os_check
    command -v systemctl >/dev/null || die 'systemd is required.'
    install -d -m 700 "$APP_STATE_DIR"
    touch "$APP_LOG"
    chmod 600 "$APP_LOG"
}

# « seedtunnel » shortcut to open the menu from anywhere. It goes into
# /usr/local/bin, in the PATH even after a « su » without a dash. A link that
# points elsewhere (an older copy of seedtunnel) is put right; a file of
# another program is left alone, and it is said.
APP_SHORTCUT="/usr/local/bin/seedtunnel"
install_shortcut() {
    local target="$APP_DIR/seedtunnel.sh"
    if [[ -L $APP_SHORTCUT ]]; then
        if [[ $(readlink -- "$APP_SHORTCUT") != "$target" ]]; then ln -sfn -- "$target" "$APP_SHORTCUT" 2>/dev/null || true; fi
    elif [[ -e $APP_SHORTCUT ]]; then
        warn '%s belongs to another program: left alone (seedtunnel is still there: %s).' "$APP_SHORTCUT" "$target"
    else
        ln -s -- "$target" "$APP_SHORTCUT" 2>/dev/null || true
    fi
}

# Only one copy at a time may change the server. The lock file says who holds
# the lock, so the message can tell which process to stop if it was forgotten.
take_lock() {
    local pid="" since="" tty="" stop
    exec 9<>"$APP_LOCK"
    if ! flock -n 9; then
        read -r pid since tty <"$APP_LOCK" || true
        if [[ $pid =~ ^[0-9]+$ && $since =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            # the process belongs to root: someone who came in by sudo needs
            # sudo to stop it too
            stop="kill $pid"
            if [[ -n ${SUDO_USER-} ]]; then stop="sudo $stop"; fi
            die 'seedtunnel is already running (process %s, started %s min ago, terminal %s).\n  If that window is gone, stop it with:  %s' \
                "$pid" "$((($(date +%s) - since) / 60))" "${tty:--}" "$stop"
        fi
        die 'seedtunnel is already running in another terminal.'
    fi
    if [[ -t 0 ]]; then tty=$(tty); fi
    printf '%s %s %s\n' "$$" "$(date +%s)" "${tty#/dev/}" >"$APP_LOCK"
}

package_installed() {
    [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == *" installed" ]]
}

# Packages installed by seedtunnel are listed in $APP_STATE_DIR/packages (with
# the dependencies they brought): a removal only takes those. An nginx that
# served another site before, for example, stays. The list starts empty on a
# new server. On a server set up by an older version (no list), what that
# version would have removed counts as installed by seedtunnel.
packages_record_init() {
    local package
    [[ ! -e $APP_STATE_DIR/packages ]] || return 0
    install -d -m 700 "$APP_STATE_DIR"
    {
        if [[ -e $APP_STATE_DIR/vpn.conf ]]; then
            for package in wireguard-tools qrencode; do
                if package_installed "$package"; then printf '%s\n' "$package"; fi
            done
        fi
        if [[ -e $APP_STATE_DIR/seedbox.conf ]]; then
            for package in transmission-daemon transmission-common nginx nginx-common certbot fail2ban inotify-tools putty-tools; do
                if package_installed "$package"; then printf '%s\n' "$package"; fi
            done
        fi
    } >"$APP_STATE_DIR/packages"
}

# Names of the installed packages, sorted
packages_installed_list() {
    dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null | awk '$1 == "installed" { print $2 }' | LC_ALL=C sort -u
}

# « sshd -t » and « sshd -T » stop at once without /run/sshd. When systemd
# starts SSH on demand (ssh.socket, Ubuntu), it only exists once someone has
# connected: made as systemd makes it (root, 755).
SSHD_RUNTIME_DIR="/run/sshd"
sshd_runtime_dir() {
    [[ -d $SSHD_RUNTIME_DIR ]] || install -d -m 755 "$SSHD_RUNTIME_DIR" 2>/dev/null || true
}

# sshd_settings [-C …] — the settings sshd really uses (empty if unreadable)
sshd_settings() {
    sshd_runtime_dir
    sshd -T "$@" 2>/dev/null || true
}

# For APT: never a question. needrestart (Ubuntu) only lists the services to
# restart: left to itself, it could restart SSH in the middle of an installation.
apt_environment() {
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
}

# apt_check_candidates PACKAGE… → stops before installing anything if APT has
# no version of one of them (on Ubuntu: the « universe » repository turned off)
apt_check_candidates() {
    local package policy
    local -a absent=()
    for package in "$@"; do
        # read whole first: « apt-cache | grep -q » fails wrongly with pipefail
        # (grep stops at the line found, apt-cache is cut off)
        policy=$(LC_ALL=C apt-cache policy "$package" 2>>"$APP_LOG") || policy=""
        grep -q '^ *Candidate: [^(]' <<<"$policy" || absent+=("$package")
    done
    ((${#absent[@]})) || return 0
    if [[ $APP_OS_ID == ubuntu ]]; then
        die 'Packages not found by APT: %s. Turn on the « universe » repository of Ubuntu, then start again:  sudo add-apt-repository universe' "${absent[*]}"
    fi
    die 'Packages not found by APT: %s. Check the repositories of APT (/etc/apt/sources.list and /etc/apt/sources.list.d), then start again.' "${absent[*]}"
}

# ufw_active → true if ufw (the firewall of Ubuntu) is on: it would block the
# VPN and the seedbox. seedtunnel never changes its rules.
ufw_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    [[ $(LC_ALL=C ufw status 2>/dev/null) == "Status: active"* ]]
}

# ufw_refuse → stops before anything is installed while ufw is on
ufw_refuse() {
    ufw_active || return 0
    die 'ufw (the firewall of Ubuntu) is on: it would block the VPN and the seedbox, and seedtunnel does not change its rules. Turn it off, then start again:  sudo ufw disable   (the firewall of seedtunnel then protects the server: seedtunnel firewall enable)'
}

# apt_install PACKAGE… — installs only what is missing. The package list is
# refreshed once per run; we wait for the dpkg lock (automatic updates often
# hold it right after boot).
apt_install() {
    local package before after
    local -a missing=()
    for package in "$@"; do package_installed "$package" || missing+=("$package"); done
    ((${#missing[@]})) || return 0
    packages_record_init
    apt_environment
    if ((!APP_APT_UPDATED)); then
        run 'Updating the package list' apt-get -o DPkg::Lock::Timeout=300 update
        APP_APT_UPDATED=1
    fi
    apt_check_candidates "${missing[@]}"
    before=$(packages_installed_list) || before=""
    run "$(t 'Installing %s' "${missing[*]}")" apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0 install -y --no-install-recommends "${missing[@]}"
    # what came with them (dependencies included) goes into the list. If the
    # installed packages cannot be listed, only the ones asked for: never the
    # whole system.
    if [[ -n $before ]] && after=$(packages_installed_list) && [[ -n $after ]]; then
        LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") >>"$APP_STATE_DIR/packages"
    else
        printf '%s\n' "${missing[@]}" >>"$APP_STATE_DIR/packages"
    fi
}

# Packages that purging PACKAGE… would take with them (APT removes what depends
# on them) although seedtunnel did not install them: one per line. Simulated,
# nothing is removed. Status 1: the simulation failed, nothing is known.
apt_purge_outsiders() {
    local simulated
    simulated=$(apt-get -s -o DPkg::Lock::Timeout=300 purge "$@" 2>>"$APP_LOG") || return 1
    awk '/^(Purg|Remv) / { sub(/:.*/, "", $2); print $2 }' <<<"$simulated" | LC_ALL=C sort -u \
        | LC_ALL=C comm -23 - <(LC_ALL=C sort -u "$APP_STATE_DIR/packages")
}

# apt_purge_checked "Description" PACKAGE… — purges them only if nothing else
# goes with them; otherwise they are kept, and it is said
apt_purge_checked() {
    local description=$1 outsiders
    shift
    if ! outsiders=$(apt_purge_outsiders "$@"); then
        warn 'Kept: %s (cannot check what removing them would take, details in %s).' "$*" "$APP_LOG"
        return 0
    fi
    if [[ -n $outsiders ]]; then
        warn 'Kept: removing %s would also remove %s, which seedtunnel did not install.' "$*" "${outsiders//$'\n'/ }"
        return 0
    fi
    run "$description" apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0 purge -y "$@"
}

# apt_purge PACKAGE… — only removes the ones installed by seedtunnel, then the
# dependencies they brought that nothing needs any more. No « autoremove »: it
# would also take packages that have nothing to do with seedtunnel.
apt_purge() {
    local list="$APP_STATE_DIR/packages" package installed
    local -a present=() orphans=()
    packages_record_init
    for package in "$@"; do
        # not installed, or there before seedtunnel: left alone
        if package_installed "$package" && grep -qxF -- "$package" "$list"; then present+=("$package"); fi
    done
    ((${#present[@]})) || return 0
    apt_environment
    apt_purge_checked "$(t 'Removing %s' "${present[*]}")" "${present[@]}"
    mapfile -t orphans < <(apt-get -s autoremove 2>/dev/null | awk '/^Remv / { sub(/:.*/, "", $2); print $2 }' \
        | grep -xF -f "$list" || true)
    if ((${#orphans[@]})); then
        apt_purge_checked "$(t 'Removing the dependencies installed with them')" "${orphans[@]}"
    fi
    # the list keeps what is still installed; left as it is if the installed
    # packages cannot be listed
    if installed=$(packages_installed_list) && [[ -n $installed ]]; then
        LC_ALL=C sort -u "$list" | LC_ALL=C comm -12 - <(printf '%s\n' "$installed") >"$list.new"
        mv -f "$list.new" "$list"
    fi
}

# Base packages + automatic security updates
base_setup() {
    packages_record_init
    apt_install curl ca-certificates openssl jq nftables procps iproute2 unattended-upgrades
    if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
        printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
            >/etc/apt/apt.conf.d/20auto-upgrades
        ok 'Automatic security updates enabled'
    fi
    log_rotation_apply
}

# --- Rotation of the log ----------------------------------------------------------
# The log is cut every month by logrotate (run every day by Debian): the last
# 6 months are kept, compressed. It no longer grows without end.
LOGROTATE_FILE="/etc/logrotate.d/seedtunnel"

log_rotation_generate() {
    cat <<EOF
# Written by seedtunnel — its log, cut every month, the last 6 months kept
$APP_LOG {
    monthly
    rotate 6
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
}
EOF
}

log_rotation_apply() {
    apt_install logrotate
    write_if_changed "$LOGROTATE_FILE" 644 root:root log_rotation_generate || true
}

# --- Kernel network hardening -----------------------------------------------------
# In /etc/sysctl.d: Debian 13 no longer reads /etc/sysctl.conf at boot.
# « * » covers every interface, including the existing ones; a leading « - »
# ignores the line when IPv6 is disabled on the server.
NET_HARDENING_FILE="/etc/sysctl.d/90-seedtunnel-network.conf"

net_hardening_generate() {
    cat <<'EOF'
# Written by seedtunnel — kernel network hardening
# Ignore ICMP redirects: nobody can divert the server's traffic
net.ipv4.conf.*.accept_redirects = 0
net.ipv4.conf.*.secure_redirects = 0
-net.ipv6.conf.*.accept_redirects = 0
# … and do not send any
net.ipv4.conf.*.send_redirects = 0
# Refuse packets that choose their own route (source routing)
net.ipv4.conf.*.accept_source_route = 0
-net.ipv6.conf.*.accept_source_route = 0
EOF
}

# The settings of the file, read back on « all » (those of IPv6 only if the
# server has IPv6): the same check for « seedtunnel apply » and the diagnostics
NET_HARDENING_IPV6_DIR="/proc/sys/net/ipv6/conf/all"
net_hardening_keys() {
    printf '%s\n' net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.secure_redirects \
        net.ipv4.conf.all.send_redirects net.ipv4.conf.all.accept_source_route
    if [[ -d $NET_HARDENING_IPV6_DIR ]]; then
        printf '%s\n' net.ipv6.conf.all.accept_redirects net.ipv6.conf.all.accept_source_route
    fi
}

# Is the hardening in force? Status 1 if one value differs, or cannot be read
net_hardening_in_force() {
    local key
    while IFS= read -r key; do
        [[ $(sysctl -n "$key" 2>/dev/null) == 0 ]] || return 1
    done < <(net_hardening_keys)
}

# systemd-sysctl, as at boot: it understands « * » and « - »
net_hardening_load() { /usr/lib/systemd/systemd-sysctl "$NET_HARDENING_FILE"; }

# Called when installing the VPN and the seedbox, and by « seedtunnel apply ».
# The settings are loaded again only if the file changed or one value differs:
# a run with nothing to fix changes nothing.
net_hardening_apply() {
    if write_if_changed "$NET_HARDENING_FILE" 644 root:root net_hardening_generate || ! net_hardening_in_force; then
        log_title 'Kernel network hardening'
        if net_hardening_load >>"$APP_LOG" 2>&1 && net_hardening_in_force; then
            ok 'Kernel network settings hardened (ICMP redirects, source routing)'
        else
            warn 'Kernel network settings not applied (details in %s).' "$APP_LOG"
        fi
    fi
}

# Removed when neither the VPN nor the seedbox is installed any more
net_hardening_cleanup() {
    if ! vpn_installed && ! seedbox_installed; then rm -f "$NET_HARDENING_FILE"; fi
}

# « 36GB free of 40GB » for the partition of a folder. The free space is green,
# yellow under 10 % or 5 GB, red under 2 GB.
# disk_level SIZE FREE (bytes) → DISK_LEVEL: bad under 2 GiB free, warn under
# 5 GiB or 10 %, ok otherwise
disk_level() {
    if (($2 < 2 * 1024 ** 3)); then
        DISK_LEVEL=bad
    elif (($2 < 5 * 1024 ** 3 || $2 * 10 < $1)); then
        DISK_LEVEL=warn
    else
        DISK_LEVEL=ok
    fi
}

disk_free_text() {
    local size="" avail="" color
    read -r size avail < <(df -B1 --output=size,avail "$1" 2>/dev/null | tail -n 1) || true
    if [[ ! $size =~ ^[0-9]+$ || ! $avail =~ ^[0-9]+$ ]] || ((size == 0)); then
        printf '?'
        return 0
    fi
    disk_level "$size" "$avail"
    case $DISK_LEVEL in
        bad) color=$C_RED ;;
        warn) color=$C_YELLOW ;;
        *) color=$C_GREEN ;;
    esac
    t '%s free%s of %s' "$color$(human_size_spaced "$avail")" "$C_RESET" "$(human_size_spaced "$size")"
}

# 38654705664 → « 36GB » (« 36Go » in French), for the tables. Rounded down,
# like disk_free_gb: never more free space than there is.
human_size() { numfmt --to=iec --round=down --suffix="$(t 'B')" "$1"; }

# 38654705664 → « 36 GB » (« 36 Go » in French), for the sentences
human_size_spaced() {
    local size number
    size=$(human_size "$1")
    number=${size%%[!0-9.,]*}
    printf '%s %s' "$number" "${size#"$number"}"
}

# Free space in whole gigabytes (GiB) on the partition of a folder; empty if it
# cannot be measured. Never a failure: under « set -e », a df that fails would
# stop the script where it is used (« free=$(disk_free_gb …) »).
disk_free_gb() {
    { df -Pk "$1" 2>/dev/null || true; } | awk 'NR == 2 { printf "%d", $4 / 1048576 }'
}

# --- Network ----------------------------------------------------------------------
# IPv4 address: four numbers from 0 to 255, without leading zero (« 010 » is
# read as 8 by some programs)
is_ipv4() {
    local IFS=. part
    local -a parts
    [[ $1 =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
    read -r -a parts <<<"$1"
    for part in "${parts[@]}"; do
        ((10#$part <= 255)) || return 1
    done
}

# IPv6 address (without an IPv4 part at the end): 8 groups of 1 to 4
# hexadecimal digits, or fewer with a single « :: » standing for the missing
# ones (one group of zeros at least)
is_ipv6() {
    local address=$1 group
    local -a groups
    [[ $address =~ ^[0-9A-Fa-f:]{2,39}$ && $address != *:::* ]] || return 1
    if [[ $address == *::* ]]; then
        [[ ${address#*::} != *::* ]] || return 1
        address=${address/::/:}
        address=${address#:}
        address=${address%:}
        [[ -n $address ]] || return 0
    fi
    [[ $address != :* && $address != *: ]] || return 1
    IFS=: read -r -a groups <<<"$address"
    if [[ $1 == *::* ]]; then
        ((${#groups[@]} <= 7)) || return 1
    else
        ((${#groups[@]} == 8)) || return 1
    fi
    for group in "${groups[@]}"; do
        [[ $group =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
}

# Port from 1 to 65535, without leading zero (« 080 » would be read as octal)
is_valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535)); }

# A WireGuard key: 32 bytes in base64, 44 characters, one line
is_wg_key() { [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }

# Network interface of the default route (eth0, ens3…)
default_interface() {
    ip -4 route show default 2>/dev/null \
        | awk '!found { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); found = 1 } }'
}

# Public IPv4: asked to outside services (the server may be behind NAT),
# otherwise the source address of the default route.
public_ipv4() {
    local ip url
    for url in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null || true)
        ip=${ip//[[:space:]]/}
        if is_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '!found { for (i = 1; i < NF; i++) if ($i == "src") { print $(i+1); found = 1 } }'
}

# Address the SSH session running seedtunnel comes from: SSH_CONNECTION, or
# else the terminal (after sudo or su). Empty from the console.
ssh_session_source() {
    local source=${SSH_CONNECTION-}
    source=${source%% *}
    if [[ -z $source ]]; then source=$(who -m 2>/dev/null | sed -n 's/.*(\([^)]*\)).*/\1/p' || true); fi
    printf '%s' "$source"
}

# nft_delete_table FAMILY NAME — removes a table of nftables if it is still
# there (stopping WireGuard or the firewall may have removed it already: no
# « Error: No such file or directory » in the log, that would look like a
# real problem to someone reading it)
nft_delete_table() {
    if nft list table "$1" "$2" &>/dev/null; then nft delete table "$1" "$2" >>"$APP_LOG" 2>&1 || true; fi
}

# Is a port already in use?  port_in_use tcp|udp PORT
port_in_use() {
    local out
    if [[ $1 == udp ]]; then
        out=$(ss -Hlun "sport = :$2" 2>/dev/null || true)
    else
        out=$(ss -Hltn "sport = :$2" 2>/dev/null || true)
    fi
    [[ -n $out ]]
}

reboot_server() {
    danger "$(t 'Restart the server')" "$(t 'The VPN and the seedbox stop for a minute or two; this connection is cut.')"
    if confirm 'Restart the server now?' n; then
        systemctl reboot
        ui_quit
    fi
}
