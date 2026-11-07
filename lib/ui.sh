#!/usr/bin/env bash
# =============================================================================
#  seedtunnel — display of the menus (« Premium Signature » interface)
#  Header, breadcrumb, state of the server, menu entries, footer, tables and
#  boxes, in pure bash (printf and ANSI codes): nothing to install.
#  Loaded by seedtunnel.sh: this file does nothing on its own.
#
#  - The functions take texts that are already translated (t first).
#  - Widths are counted in characters by ui_len, never with printf '%-10s',
#    which counts bytes: « é », « ● » or « ─ » would shift the columns.
#  - Nothing goes past UI_WIDTH: the width of the terminal minus one, 79 at
#    most (PuTTY opens with 80 columns). UI_COLUMNS replaces the width of the
#    terminal (tests, tools/preview.sh).
#  - Results go into variables (UI_LEN, UI_CUT…) rather than through $(…):
#    no subshell for every piece of text.
# =============================================================================

UI_WIDTH=79
UI_TEXT_IN_BYTES=0
UI_SERVER=""
UI_SYSTEM=""
UI_STATUS_LEVELS=()
UI_STATUS_LABELS=()
UI_STATUS_STATES=()
UI_STATUS_DETAILS=()
UI_STATUS_SHORT=()
UI_MENU_KEYS=()
UI_MENU_LABELS=()
UI_FIELD_LABELS=()
UI_FIELD_VALUES=()

# Does the locale count the characters of a text (UTF-8), or its bytes (C,
# POSIX: LANG not set, cron…)? Decided once, and the locale is never changed
# here: bash would print a warning at every change when the locale of the
# session does not exist on the server (LC_CTYPE=UTF-8 sent by a Mac…).
ui_text_check() {
    local sample=é
    if ((${#sample} == 1)); then UI_TEXT_IN_BYTES=0; else UI_TEXT_IN_BYTES=1; fi
}
ui_text_check

# --- Measuring and cutting text ----------------------------------------------------

# ui_strip TEXT → UI_STRIP: the text without its color codes
ui_strip() {
    local text=$1 rest
    while [[ $text == *$'\e['* ]]; do
        rest=${text#*$'\e['}
        text=${text%%$'\e['*}${rest#*m}
    done
    UI_STRIP=$text
}

# ui_len TEXT → UI_LEN: number of characters shown (color codes left out; in a
# locale that counts bytes, the bytes continuing a UTF-8 character are not
# counted)
ui_len() {
    local continuing
    ui_strip "$1"
    if ((UI_TEXT_IN_BYTES)); then
        continuing=${UI_STRIP//[^$'\x80'-$'\xbf']/}
        UI_LEN=$((${#UI_STRIP} - ${#continuing}))
    else
        UI_LEN=${#UI_STRIP}
    fi
}

# ui_take TEXT N → UI_TAKE: the first N characters, UI_REST: the others
# (text without color codes)
ui_take() {
    local text=$1 max=$2 i=0 count=0
    if ((!UI_TEXT_IN_BYTES)); then
        UI_TAKE=${text:0:max}
        UI_REST=${text:max}
        return 0
    fi
    while ((i < ${#text})); do
        if [[ ${text:i:1} != [$'\x80'-$'\xbf'] ]]; then
            if ((count == max)); then break; fi
            count=$((count + 1))
        fi
        i=$((i + 1))
    done
    UI_TAKE=${text:0:i}
    UI_REST=${text:i}
}

# ui_cut TEXT N → UI_CUT: the text, or its beginning followed by « … » when it
# is longer than N characters (the colors are then removed)
ui_cut() {
    local max=$2
    ui_len "$1"
    if ((UI_LEN <= max)); then
        UI_CUT=$1
    elif ((max < 1)); then
        UI_CUT=""
    else
        ui_take "$UI_STRIP" $((max - 1))
        UI_CUT="$UI_TAKE…"
    fi
}

# ui_repeat TEXT N → UI_REPEAT: TEXT N times
ui_repeat() {
    local spaces count=$2
    if ((count < 0)); then count=0; fi
    printf -v spaces '%*s' "$count" ''
    UI_REPEAT=${spaces// /$1}
}

# ui_pad TEXT N → UI_PAD: the text followed by spaces, N characters in all
ui_pad() {
    ui_len "$1"
    ui_repeat ' ' $(($2 - UI_LEN))
    UI_PAD=$1$UI_REPEAT
}

# ui_wrap TEXT N → UI_LINES: the text in lines of N characters at most, cut
# between words (a word longer than a line, a path for example, is split:
# never shortened)
ui_wrap() {
    local text=$1 max=$2 word line="" length=0 size
    local -a words=()
    UI_LINES=()
    if ((max < 1)); then max=1; fi
    ui_len "$text"
    if ((UI_LEN <= max)); then
        UI_LINES=("$text")
        return 0
    fi
    read -r -a words <<<"$UI_STRIP"
    for word in "${words[@]}"; do
        ui_len "$word"
        size=$UI_LEN
        while ((size > max)); do
            if ((length > 0)); then UI_LINES+=("$line"); fi
            ui_take "$word" "$max"
            UI_LINES+=("$UI_TAKE")
            word=$UI_REST
            line=""
            length=0
            ui_len "$word"
            size=$UI_LEN
        done
        if ((size == 0)); then
            continue
        elif ((length == 0)); then
            line=$word
            length=$size
        elif ((length + 1 + size <= max)); then
            line+=" $word"
            length=$((length + 1 + size))
        else
            UI_LINES+=("$line")
            line=$word
            length=$size
        fi
    done
    if ((length > 0)); then UI_LINES+=("$line"); fi
}

# ui_print TEXT — prints a line, cut to the width of the screen if needed
ui_print() {
    ui_cut "$1" "$UI_WIDTH"
    printf '%s\n' "$UI_CUT"
}

# ui_line LEFT RIGHT — LEFT, and RIGHT against the right edge if there is room
ui_line() {
    local left=$1 right=${2-} size
    ui_len "$left"
    size=$UI_LEN
    if [[ -n $right ]]; then
        ui_len "$right"
        if ((size + 2 + UI_LEN <= UI_WIDTH)); then
            ui_repeat ' ' $((UI_WIDTH - size - UI_LEN))
            printf '%s%s%s\n' "$left" "$UI_REPEAT" "$right"
            return 0
        fi
    fi
    ui_print "$left"
}

# --- Screen -----------------------------------------------------------------------

# ui_width → UI_WIDTH: columns of the terminal minus one, between 20 and 79
ui_width() {
    local _rows="" columns=${UI_COLUMNS-}
    if [[ -z $columns ]]; then
        read -r _rows columns < <({ stty size </dev/tty || true; } 2>/dev/null) || true
    fi
    if [[ ! $columns =~ ^[0-9]+$ ]] || ((columns == 0)); then columns=80; fi
    UI_WIDTH=$((columns - 1))
    if ((UI_WIDTH > 79)); then UI_WIDTH=79; fi
    if ((UI_WIDTH < 20)); then UI_WIDTH=20; fi
}

# ui_screen — new screen: cleared in the menus, width measured again (the
# window may have been resized)
ui_screen() {
    if ((INTERACTIVE)); then clear 2>/dev/null || true; fi
    ui_width
}

# Name of the server and of its system, for the header (read once)
ui_server_names() {
    local id="" name="" version="" pretty=""
    if [[ -z $UI_SERVER ]]; then UI_SERVER=${HOSTNAME:-$(uname -n)}; fi
    [[ -z $UI_SYSTEM ]] || return 0
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        read -r id name version pretty < <(
            . /etc/os-release
            printf '%s %s %s %s\n' "${ID:-?}" "${NAME%% *}" "${VERSION_ID:-?}" "${PRETTY_NAME:-}"
        ) || true
    fi
    if [[ $id == debian ]]; then
        UI_SYSTEM="Debian $version"
    else
        UI_SYSTEM=${pretty:-${name:-Linux}}
    fi
}

# Header: the emblem, the name, the version, and the server on the right.
# Without room for the emblem, two plain lines.
ui_header() {
    local name badge subtitle
    ui_server_names
    name="${C_BOLD}Seed$C_RESET${C_BRAND}Tunnel$C_RESET"
    if [[ -n $C_BADGE ]]; then badge="$C_BADGE v$APP_VERSION $C_RESET"; else badge="v$APP_VERSION"; fi
    subtitle=$(t 'WireGuard VPN · private seedbox')
    ui_cut "$UI_SERVER" 24
    if ((UI_WIDTH >= 60)); then
        ui_line "      $C_BRAND┌─────────┐$C_RESET" "$C_GREY$UI_CUT$C_RESET"
        ui_line "  $C_GREY────$C_BRAND┤ ●═════● ├$C_GREY────$C_RESET  $name  $badge" "$C_GREY$UI_SYSTEM$C_RESET"
        ui_line "      $C_BRAND└─────────┘$C_RESET      $C_GREY$subtitle$C_RESET"
    else
        ui_line "$name  $badge" "$C_GREY$UI_CUT$C_RESET"
        ui_line "$C_GREY$subtitle$C_RESET" "$C_GREY$UI_SYSTEM$C_RESET"
    fi
}

# ui_rule — thin line across the screen
ui_rule() {
    ui_repeat ─ "$UI_WIDTH"
    printf '%s%s%s\n' "$C_GREY" "$UI_REPEAT" "$C_RESET"
}

# ui_crumbs PART… — where we are: « seedtunnel › VPN › Clients »
ui_crumbs() {
    local line="  ${C_BRAND}seedtunnel$C_RESET"
    while (($# > 1)); do
        line+=" $C_GREY›$C_RESET $1"
        shift
    done
    if (($#)); then line+=" $C_GREY›$C_RESET $C_BOLD$1$C_RESET"; fi
    ui_print "$line"
}

# --- States -----------------------------------------------------------------------
# ui_level LEVEL → UI_COLOR and UI_MARK: ok (green), info (pink), warn
# (yellow), bad (red), off (grey, empty circle)
ui_level() {
    UI_MARK="●"
    case $1 in
        ok) UI_COLOR=$C_GREEN ;;
        info) UI_COLOR=$C_BRAND ;;
        warn) UI_COLOR=$C_YELLOW ;;
        bad) UI_COLOR=$C_RED ;;
        *)
            UI_COLOR=$C_GREY
            UI_MARK="○"
            ;;
    esac
}

# ui_status_add LEVEL NAME STATE [DETAIL [SHORT DETAIL]] — one part of the
# server, shown by ui_status_show. STATE: 9 characters at most in a block.
# The details of the blocks go together on a line below them (« last backup
# 3 days ago »); the list has them next to the name, SHORT DETAIL if given
# (« 3 days ago »).
ui_status_add() {
    UI_STATUS_LEVELS+=("$1")
    UI_STATUS_LABELS+=("$2")
    UI_STATUS_STATES+=("$3")
    UI_STATUS_DETAILS+=("${4-}")
    UI_STATUS_SHORT+=("${5:-${4-}}")
}

# Blocks side by side when there is room for them (5 blocks: 79 columns, so a
# terminal of 80), otherwise an aligned list with the details on each line
ui_status_show() {
    local count=${#UI_STATUS_LABELS[@]}
    if ((count > 0 && UI_WIDTH >= count * 16 - 1)); then
        ui_status_blocks
    else
        ui_status_list
    fi
    UI_STATUS_LEVELS=()
    UI_STATUS_LABELS=()
    UI_STATUS_STATES=()
    UI_STATUS_DETAILS=()
    UI_STATUS_SHORT=()
}

ui_status_blocks() {
    local i top="" names="" states="" bottom="" gap="" details="" name state edge
    ui_repeat ─ 13
    edge=$UI_REPEAT
    for i in "${!UI_STATUS_LABELS[@]}"; do
        ui_level "${UI_STATUS_LEVELS[i]}"
        ui_cut "${UI_STATUS_LABELS[i]}" 11
        ui_pad "$UI_CUT" 11
        name=$UI_PAD
        ui_cut "${UI_STATUS_STATES[i]}" 9
        ui_pad "$UI_CUT" 9
        state=$UI_PAD
        top+="$gap$UI_COLOR┌$edge┐$C_RESET"
        names+="$gap$UI_COLOR│$C_RESET $C_BOLD$name$C_RESET $UI_COLOR│$C_RESET"
        states+="$gap$UI_COLOR│ $UI_MARK $state │$C_RESET"
        bottom+="$gap$UI_COLOR└$edge┘$C_RESET"
        gap=" "
        if [[ -n ${UI_STATUS_DETAILS[i]} ]]; then details+="${details:+ · }${UI_STATUS_DETAILS[i]}"; fi
    done
    printf '%s\n' "$top" "$names" "$states" "$bottom"
    if [[ -n $details ]]; then ui_print "  $C_GREY$details$C_RESET"; fi
}

ui_status_list() {
    local i names=0 states=0 line
    for i in "${!UI_STATUS_LABELS[@]}"; do
        ui_len "${UI_STATUS_LABELS[i]}"
        if ((UI_LEN > names)); then names=$UI_LEN; fi
        ui_len "${UI_STATUS_STATES[i]}"
        if ((UI_LEN > states)); then states=$UI_LEN; fi
    done
    for i in "${!UI_STATUS_LABELS[@]}"; do
        ui_level "${UI_STATUS_LEVELS[i]}"
        ui_pad "${UI_STATUS_LABELS[i]}" "$names"
        line="  $C_BOLD$UI_PAD$C_RESET  "
        if [[ -n ${UI_STATUS_SHORT[i]} ]]; then
            ui_pad "${UI_STATUS_STATES[i]}" "$states"
            line+="$UI_COLOR$UI_MARK $UI_PAD$C_RESET  $C_GREY${UI_STATUS_SHORT[i]}$C_RESET"
        else
            line+="$UI_COLOR$UI_MARK ${UI_STATUS_STATES[i]}$C_RESET"
        fi
        ui_print "$line"
    done
}

# ui_field_add NAME VALUE / ui_fields_show — aligned « name   value » lines
ui_field_add() {
    UI_FIELD_LABELS+=("$1")
    UI_FIELD_VALUES+=("$2")
}

ui_fields_show() {
    local i width=0
    for i in "${!UI_FIELD_LABELS[@]}"; do
        ui_len "${UI_FIELD_LABELS[i]}"
        if ((UI_LEN > width)); then width=$UI_LEN; fi
    done
    for i in "${!UI_FIELD_LABELS[@]}"; do
        ui_pad "${UI_FIELD_LABELS[i]}" "$width"
        ui_print "  $C_GREY$UI_PAD$C_RESET  ${UI_FIELD_VALUES[i]}"
    done
    UI_FIELD_LABELS=()
    UI_FIELD_VALUES=()
}

# --- Menus ------------------------------------------------------------------------

# ui_key KEY → UI_KEY: key of a menu entry, [K] with the brackets in grey and
# the key in pink (no background). ui_keycap KEY: key of the bottom line (B,
# R, Q), white on pink like the version; [K] without colors. 3 characters
# either way. (Choices of Neil, 7 Nov. 2026.)
ui_key() {
    UI_KEY="${C_GREY}[$C_RESET$C_BRAND${1^^}$C_RESET$C_GREY]$C_RESET"
}

ui_keycap() {
    if [[ -n $C_BADGE ]]; then UI_KEY="$C_BADGE ${1^^} $C_RESET"; else UI_KEY="[${1^^}]"; fi
}

# ui_menu_add KEY TEXT / ui_menu_gap / ui_menu_show — entries of a menu. Two
# columns when the screen is wide enough (70) for every text, and there are
# at least 6 entries; one column otherwise, with the gaps.
ui_menu_add() {
    UI_MENU_KEYS+=("$1")
    UI_MENU_LABELS+=("$2")
}

ui_menu_gap() {
    UI_MENU_KEYS+=("")
    UI_MENU_LABELS+=("")
}

ui_menu_show() {
    local i half column=$(((UI_WIDTH - 2) / 2)) two=0 line
    local -a keys=() labels=()
    for i in "${!UI_MENU_KEYS[@]}"; do
        [[ -n ${UI_MENU_KEYS[i]} ]] || continue
        keys+=("${UI_MENU_KEYS[i]}")
        labels+=("${UI_MENU_LABELS[i]}")
    done
    half=$(((${#keys[@]} + 1) / 2))
    if ((UI_WIDTH >= 70 && ${#keys[@]} >= 6)); then
        two=1
        for i in "${!labels[@]}"; do
            ui_len "${labels[i]}"
            if ((i < half && UI_LEN > column - 6 || i >= half && UI_LEN > UI_WIDTH - 2 - column - 4)); then two=0; fi
        done
    fi
    if ((two)); then
        for ((i = 0; i < half; i++)); do
            ui_key "${keys[i]}"
            ui_pad "$UI_KEY ${labels[i]}" "$column"
            line="  $UI_PAD"
            if ((i + half < ${#keys[@]})); then
                ui_key "${keys[i + half]}"
                line+="$UI_KEY ${labels[i + half]}"
            fi
            ui_print "$line"
        done
    else
        for i in "${!UI_MENU_KEYS[@]}"; do
            if [[ -z ${UI_MENU_KEYS[i]} ]]; then
                echo
                continue
            fi
            ui_key "${UI_MENU_KEYS[i]}"
            ui_print "  $UI_KEY ${UI_MENU_LABELS[i]}"
        done
    fi
    UI_MENU_KEYS=()
    UI_MENU_LABELS=()
}

# ui_footer KEY TEXT [KEY TEXT…] — bottom of a menu: a line, then the keys
# that are always there, with « Your choice › » on the right of the same line
# (on its own line when there is no room). Prints all but the last line, which
# is left in UI_PROMPT: it is the question.
ui_footer() {
    local shown="" prompt size
    while (($# >= 2)); do
        ui_keycap "$1"
        shown+="${shown:+    }$UI_KEY $2"
        shift 2
    done
    prompt="$C_BRAND$(t 'Your choice') ›$C_RESET "
    ui_rule
    ui_len "  $shown"
    size=$UI_LEN
    ui_len "$prompt"
    if ((size + 2 + UI_LEN <= UI_WIDTH)); then
        ui_repeat ' ' $((UI_WIDTH - size - UI_LEN))
        UI_PROMPT="  $shown$UI_REPEAT$prompt"
    else
        ui_print "  $shown"
        UI_PROMPT="  $prompt"
    fi
}

# ui_ask_choice VARIABLE KEY TEXT [KEY TEXT…] — the footer, and the answer
# without the spaces around it
ui_ask_choice() {
    local _uc_var=$1 _uc_answer
    shift
    ((INTERACTIVE)) || die 'Question asked outside interactive mode: %s' "$(t 'Your choice')"
    ui_footer "$@"
    IFS= read -r -p "$UI_PROMPT" _uc_answer || {
        echo
        exit 130
    }
    _uc_answer=${_uc_answer#"${_uc_answer%%[![:space:]]*}"}
    _uc_answer=${_uc_answer%"${_uc_answer##*[![:space:]]}"}
    printf -v "$_uc_var" '%s' "$_uc_answer"
}

# ui_menu_keys [back] → UI_KEYS: the usual keys, [B] Back (in the submenus),
# [R] Refresh, [Q] Quit
ui_menu_keys() {
    UI_KEYS=()
    if [[ ${1-} == back ]]; then UI_KEYS+=(b "$(t 'Back')"); fi
    UI_KEYS+=(r "$(t 'Refresh')" q "$(t 'Quit')")
}

# ui_menu_ask VARIABLE [back] — bottom of a menu with the usual keys
ui_menu_ask() {
    ui_menu_keys "${2-}"
    ui_ask_choice "$1" "${UI_KEYS[@]}"
}

# ui_pause — after an action: « Enter ↵ back · Q quit ». Status 1 for Q.
ui_pause() {
    local answer
    ((INTERACTIVE)) || return 0
    echo
    IFS= read -r -p "  $C_GREY$(t 'Enter ↵ back · Q quit')$C_RESET " answer || {
        echo
        exit 130
    }
    [[ ${answer//[[:space:]]/} != [qQ] ]]
}

# --- Tables and boxes --------------------------------------------------------------

# ui_cells ROW → UI_CELLS: the cells of a row, separated by tabs (empty cells
# kept)
ui_cells() {
    local row=$1
    UI_CELLS=()
    while [[ $row == *$'\t'* ]]; do
        UI_CELLS+=("${row%%$'\t'*}")
        row=${row#*$'\t'}
    done
    UI_CELLS+=("$row")
}

# ui_table HEADER [ROW…] — columns separated by tabs, aligned; a line too long
# for the screen is cut at the end
ui_table() {
    local row i line total=0 header=1
    local -a widths=()
    for row in "$@"; do
        ui_cells "$row"
        for i in "${!UI_CELLS[@]}"; do
            ui_len "${UI_CELLS[i]}"
            if ((UI_LEN > ${widths[i]:-0})); then widths[i]=$UI_LEN; fi
        done
    done
    for i in "${!widths[@]}"; do total=$((total + widths[i] + 2)); done
    for row in "$@"; do
        ui_cells "$row"
        line=""
        for i in "${!UI_CELLS[@]}"; do
            if ((i < ${#UI_CELLS[@]} - 1)); then
                ui_pad "${UI_CELLS[i]}" $((widths[i] + 2))
                line+=$UI_PAD
            else
                line+=${UI_CELLS[i]}
            fi
        done
        if ((header)); then
            ui_print "  $C_GREY$line$C_RESET"
            if ((total - 2 > UI_WIDTH - 2)); then total=$UI_WIDTH; fi
            ui_repeat ─ $((total - 2))
            printf '  %s%s%s\n' "$C_GREY" "$UI_REPEAT" "$C_RESET"
            header=0
        else
            ui_print "  $line"
        fi
    done
}

# ui_box LEVEL TITLE [LINE…] — framed message: bad (red, « ! »), ok (green,
# « ✔ »), warn (yellow), info (pink). Long lines are wrapped.
ui_box() {
    local level=$1 title=$2 mark line part width inner
    shift 2
    ui_level "$level"
    case $level in
        ok) mark="✔" ;;
        bad | warn) mark="!" ;;
        *) mark="●" ;;
    esac
    ui_len "$title"
    width=$((UI_LEN + 8))
    for line in "$@"; do
        ui_len "$line"
        if ((UI_LEN + 4 > width)); then width=$((UI_LEN + 4)); fi
    done
    if ((width > UI_WIDTH - 2)); then width=$((UI_WIDTH - 2)); fi
    inner=$((width - 4))
    ui_cut "$title" $((width - 8))
    title=$UI_CUT
    ui_len "$title"
    ui_repeat ─ $((width - UI_LEN - 7))
    printf '  %s┌─ %s%s %s%s %s┐%s\n' "$UI_COLOR" "$C_BOLD" "$mark" "$title" "$C_RESET$UI_COLOR" "$UI_REPEAT" "$C_RESET"
    for line in "$@"; do
        ui_wrap "$line" "$inner"
        for part in "${UI_LINES[@]}"; do
            ui_pad "$part" "$inner"
            printf '  %s│%s %s %s│%s\n' "$UI_COLOR" "$C_RESET" "$UI_PAD" "$UI_COLOR" "$C_RESET"
        done
    done
    ui_repeat ─ $((width - 2))
    printf '  %s└%s┘%s\n' "$UI_COLOR" "$UI_REPEAT" "$C_RESET"
}
