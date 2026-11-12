#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
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
# The menus we are in, for the breadcrumb of the screens (section)
UI_PLACE=()
# Status of an action of a menu that asks to leave seedtunnel (ui_quit)
UI_QUIT_STATUS=120

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

# ui_wrap TEXT N [whole] → UI_LINES: the text in lines of N characters at
# most, cut between words (a word longer than a line, a path for example, is
# split: never shortened). whole: such a word goes on a line of its own,
# whole (an address to copy).
ui_wrap() {
    local text=$1 max=$2 whole=${3-} word line="" length=0 size
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
        if [[ -n $whole ]] && ((size > max)); then
            if ((length > 0)); then UI_LINES+=("$line"); fi
            UI_LINES+=("$word")
            line=""
            length=0
            continue
        fi
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

# ui_text — the lines read on the standard input (a long text of lang/), each
# one wrapped to the width of the screen: its beginning as it is (aligned
# columns kept), the rest on the next lines, under the value of a « Name :
# value » line, indented 2 more otherwise. A word longer than a line (an
# address to copy, a path) is never cut: a terminal copies it whole when it
# only wraps it on the screen. Nor a command after two spaces (« … :
# seedtunnel vpn share NAME »). « and » stay with their word (joined by
# a no-break space).
ui_text() {
    local line indent head part name next nbsp=$'\xc2\xa0' glue=$'\x01' command="(seedtunnel|sudo|rsync|systemctl|journalctl) "
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line//« /«$nbsp}
        line=${line// »/$nbsp»}
        indent=${line%%[! ]*}
        # a command after two spaces stays on one line (glued for the time of
        # the wrapping)
        if [[ ${line#"$indent"} =~ ^(.*[^ ])"  "($command.*)$ ]]; then
            line="$indent${BASH_REMATCH[1]}  ${BASH_REMATCH[2]// /$glue}"
        fi
        ui_len "$line"
        if ((UI_LEN <= UI_WIDTH)) || [[ ${line#"$indent"} != *" "* ]]; then
            printf '%s\n' "${line//$glue/ }"
            continue
        fi
        # the beginning: up to the last space that fits
        ui_take "$UI_STRIP" $((UI_WIDTH + 1))
        head=${UI_TAKE% *}
        head=${head%"${head##*[! ]}"}
        printf '%s\n' "${head//$glue/ }"
        part=${UI_STRIP:${#head}}
        part=${part#"${part%%[! ]*}"}
        # « Name : value »: the next lines under the value
        name=${line#"$indent"}
        name=${name%%" : "*}
        if [[ $line == *" : "* ]] && ((${#name} <= 16)); then
            printf -v next '%*s' $((${#indent} + ${#name} + 3)) ''
        else
            next="$indent  "
        fi
        ui_wrap "$part" $((UI_WIDTH - ${#next})) whole
        for part in "${UI_LINES[@]}"; do printf '%s%s\n' "$next" "${part//$glue/ }"; done
    done
}

# ui_paragraph TEXT — a paragraph wrapped to the width of the screen, every
# line indented 2. The French « : », « ? », « ! » and « » » stay with the word
# before them, « « » with the word after it.
ui_paragraph() {
    local part
    ui_glue "$1"
    ui_wrap "$UI_GLUED" $((UI_WIDTH - 2))
    for part in "${UI_LINES[@]}"; do printf '  %s\n' "${part//$'\x01'/ }"; done
}

# ui_wrap_words TEXT N → UI_LINES: TEXT in lines of N characters at most, cut
# between words, the words keeping their colors (each colored part of TEXT is
# one word: a port, an address). A word longer than a line goes alone on its
# line, whole. French punctuation glued (ui_glue): \x01 to put back as spaces.
ui_wrap_words() {
    local max=$2 word line="" length=0
    local -a words=()
    UI_LINES=()
    ui_glue "$1"
    read -r -a words <<<"$UI_GLUED"
    for word in "${words[@]}"; do
        ui_len "$word"
        if ((length == 0)); then
            line=$word
            length=$UI_LEN
        elif ((length + 1 + UI_LEN <= max)); then
            line+=" $word"
            length=$((length + 1 + UI_LEN))
        else
            UI_LINES+=("$line")
            line=$word
            length=$UI_LEN
        fi
    done
    if ((length > 0)); then UI_LINES+=("$line"); fi
}

# ui_group TITLE [WIDTH] — a part of a screen: its title (« ● » in pink, the
# title in bold), then the fields added with ui_field_add: labels in grey,
# padded to WIDTH (the widest label of the screen, so that every part lines
# up; their own widest by default), values wrapped under themselves. Less
# than 28 columns left for the values: each value under its label.
ui_group() {
    local title=$1 width=${2:-0} i room part name indent first=1
    for i in "${!UI_FIELD_LABELS[@]}"; do
        ui_len "${UI_FIELD_LABELS[i]}"
        if ((UI_LEN > width)); then width=$UI_LEN; fi
    done
    ui_wrap_words "$title" $((UI_WIDTH - 4))
    for part in "${UI_LINES[@]}"; do
        if ((first)); then
            printf '  %s●%s %s%s%s\n' "$C_BRAND$C_BOLD" "$C_RESET" "$C_BOLD" "${part//$'\x01'/ }" "$C_RESET"
            first=0
        else
            printf '    %s%s%s\n' "$C_BOLD" "${part//$'\x01'/ }" "$C_RESET"
        fi
    done
    room=$((UI_WIDTH - 4 - width - 2))
    for i in "${!UI_FIELD_LABELS[@]}"; do
        if ((room >= 28)); then
            ui_pad "${UI_FIELD_LABELS[i]}" "$width"
            name="    $C_GREY$UI_PAD$C_RESET  "
            printf -v indent '%*s' $((4 + width + 2)) ''
            ui_wrap_words "${UI_FIELD_VALUES[i]}" "$room"
        else
            printf '    %s%s%s\n' "$C_GREY" "${UI_FIELD_LABELS[i]}" "$C_RESET"
            name="      "
            indent=$name
            ui_wrap_words "${UI_FIELD_VALUES[i]}" $((UI_WIDTH - 6))
        fi
        for part in "${UI_LINES[@]}"; do
            printf '%s%s\n' "$name" "${part//$'\x01'/ }"
            name=$indent
        done
    done
    UI_FIELD_LABELS=()
    UI_FIELD_VALUES=()
}

# ui_print_wrapped START INDENT TEXT [END] — START then TEXT, going on under
# INDENT between words (colors kept, ui_wrap_words) when too long for the
# window. A word wider than the room left is cut (a name, in a field).
ui_print_wrapped() {
    local start=$1 indent=$2 text=$3 end=${4-} room part first=1
    ui_len "$start"
    room=$((UI_WIDTH - UI_LEN))
    if ((room < 8)); then
        ui_print "$start$text$end"
        return 0
    fi
    ui_wrap_words "$text" "$room"
    for part in "${UI_LINES[@]}"; do
        part=${part//$'\x01'/ }
        ui_len "$part"
        if ((UI_LEN > room)); then
            ui_cut "$part" "$room"
            part=$UI_CUT
        fi
        if ((first)); then
            printf '%s%s%s\n' "$start" "$part" "$end"
            first=0
        else
            printf '%s%s%s\n' "$indent" "$part" "$end"
        fi
    done
}

# ui_glue TEXT → UI_GLUED: the spaces before « : », « ? », « ! », « ; » and
# « » », and after « « », replaced by \x01 for the time of a ui_wrap (put back
# as spaces when printed)
ui_glue() {
    local sign
    UI_GLUED=$1
    for sign in : '?' '!' ';' »; do UI_GLUED=${UI_GLUED//" $sign"/$'\x01'$sign}; done
    UI_GLUED=${UI_GLUED//"« "/«$'\x01'}
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

# ui_terminal_size → « LINES COLUMNS » of the terminal, nothing if unknown
ui_terminal_size() {
    { stty size </dev/tty || true; } 2>/dev/null
}

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
    if [[ -z $UI_SERVER ]]; then UI_SERVER=${HOSTNAME:-$(uname -n)}; fi
    [[ -z $UI_SYSTEM ]] || return 0
    if [[ -z $APP_OS_ID && -r $APP_OS_RELEASE ]]; then os_read; fi
    case $APP_OS_ID in
        debian) UI_SYSTEM="Debian $APP_OS_VERSION" ;;
        ubuntu) UI_SYSTEM="Ubuntu $APP_OS_VERSION" ;;
        *) UI_SYSTEM=${APP_OS_DESCRIPTION:-Linux} ;;
    esac
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
# ui_level LEVEL → UI_COLOR and UI_MARK: ok and good (green), info (pink),
# warn (yellow), bad (red), off (grey, empty circle)
ui_level() {
    UI_MARK="●"
    case $1 in
        ok | good) UI_COLOR=$C_GREEN ;;
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
    ui_status_reset
}

ui_status_reset() {
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
    if [[ -n $details ]]; then ui_print_joined "  $C_GREY" "  $C_GREY" "$details" "$C_RESET"; fi
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

# ui_print_joined START INDENT TEXT [END] — START then TEXT, END at the end of
# each line. Too long for the window, TEXT goes on to the next line (INDENT,
# then « · ») at a « · »: never cut, a cut line could hide the state of a
# service or a date. Without « · », TEXT goes on under itself, between words.
ui_print_joined() {
    local start=$1 indent=$2 value=$3 end=${4-} line="" part prefix next
    local -a parts=()
    ui_len "$start$value"
    if ((UI_LEN <= UI_WIDTH)); then
        ui_print "$start$value$end"
        return 0
    fi
    while [[ -n $value ]]; do
        parts+=("${value%%" · "*}")
        if [[ $value == *" · "* ]]; then value=${value#*" · "}; else value=""; fi
    done
    # the next lines of a part: under it (after « · » for the next parts)
    prefix=$start
    next=$indent
    for part in "${parts[@]}"; do
        # on the line being filled
        if [[ -n $line ]]; then
            ui_len "$line · $part"
            if ((UI_LEN <= UI_WIDTH)); then
                line+=" · $part"
                continue
            fi
            printf '%s%s\n' "$line" "$end"
            line=""
        fi
        # at the start of a line: whole, or wrapped between words
        ui_len "$prefix$part"
        if ((UI_LEN <= UI_WIDTH)); then
            line="$prefix$part"
        else
            ui_print_wrapped "$prefix" "$next" "$part" "$end"
        fi
        prefix="$indent· "
        next="$indent  "
    done
    if [[ -n $line ]]; then printf '%s%s\n' "$line" "$end"; fi
}

ui_fields_show() {
    local i width=0 indent
    for i in "${!UI_FIELD_LABELS[@]}"; do
        ui_len "${UI_FIELD_LABELS[i]}"
        if ((UI_LEN > width)); then width=$UI_LEN; fi
    done
    printf -v indent '%*s' $((width + 4)) ''
    for i in "${!UI_FIELD_LABELS[@]}"; do
        ui_pad "${UI_FIELD_LABELS[i]}" "$width"
        ui_print_joined "  $C_GREY$UI_PAD$C_RESET  " "$indent" "${UI_FIELD_VALUES[i]}"
    done
    UI_FIELD_LABELS=()
    UI_FIELD_VALUES=()
}

# --- Menus ------------------------------------------------------------------------

# ui_key KEY → UI_KEY: key of a menu entry, [K] with the brackets in grey and
# the key in pink (no background). ui_keycap KEY: key of the bottom line (B,
# R, Q), white on pink like the version; [K] without colors. 3 characters
# either way.
ui_key() {
    UI_KEY="${C_GREY}[$C_RESET$C_BRAND${1^^}$C_RESET$C_GREY]$C_RESET"
}

ui_keycap() {
    if [[ -n $C_BADGE ]]; then UI_KEY="$C_BADGE ${1^^} $C_RESET"; else UI_KEY="[${1^^}]"; fi
}

# ui_menu_add KEY TEXT / ui_menu_gap / ui_menu_show — entries of a menu. Two
# columns when the screen is wide enough (70) for every text, and there are
# at least 6 entries; one column otherwise, with the gaps. With a key of two
# characters ([10]), the shorter ones get a space before them: the texts stay
# aligned.
ui_menu_add() {
    UI_MENU_KEYS+=("$1")
    UI_MENU_LABELS+=("$2")
}

ui_menu_gap() {
    UI_MENU_KEYS+=("")
    UI_MENU_LABELS+=("")
}

ui_menu_show() {
    local i half column=$(((UI_WIDTH - 2) / 2)) two=0 line wide=1
    local -a keys=() labels=()
    for i in "${!UI_MENU_KEYS[@]}"; do
        [[ -n ${UI_MENU_KEYS[i]} ]] || continue
        keys+=("${UI_MENU_KEYS[i]}")
        labels+=("${UI_MENU_LABELS[i]}")
        if ((${#UI_MENU_KEYS[i]} > wide)); then wide=${#UI_MENU_KEYS[i]}; fi
    done
    half=$(((${#keys[@]} + 1) / 2))
    if ((UI_WIDTH >= 70 && ${#keys[@]} >= 6)); then
        two=1
        for i in "${!labels[@]}"; do
            ui_len "${labels[i]}"
            if ((i < half && UI_LEN > column - 5 - wide || i >= half && UI_LEN > UI_WIDTH - 2 - column - 3 - wide)); then two=0; fi
        done
    fi
    if ((two)); then
        for ((i = 0; i < half; i++)); do
            ui_menu_key "${keys[i]}" "$wide"
            ui_pad "$UI_KEY ${labels[i]}" "$column"
            line="  $UI_PAD"
            if ((i + half < ${#keys[@]})); then
                ui_menu_key "${keys[i + half]}" "$wide"
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
            ui_menu_key "${UI_MENU_KEYS[i]}" "$wide"
            ui_print "  $UI_KEY ${UI_MENU_LABELS[i]}"
        done
    fi
    UI_MENU_KEYS=()
    UI_MENU_LABELS=()
}

# ui_menu_key KEY WIDTH → UI_KEY: the key of an entry, with spaces before it
# up to WIDTH characters (the longest key of the menu)
ui_menu_key() {
    local spaces
    ui_key "$1"
    printf -v spaces '%*s' "$(($2 - ${#1}))" ''
    UI_KEY="$spaces$UI_KEY"
}

# ui_choices KEY LABEL NOTE [KEY LABEL NOTE…] — entries of a menu, each with
# a note in grey that says what it does: beside the labels (aligned), wrapped
# under itself, when it has at least 30 columns there; otherwise under its
# label, indented. The notes are never cut.
ui_choices() {
    local width=0 column i part first indent
    local -a keys=() labels=() notes=()
    while (($# >= 3)); do
        keys+=("$1")
        labels+=("$2")
        notes+=("$3")
        ui_len "$2"
        if ((UI_LEN > width)); then width=$UI_LEN; fi
        shift 3
    done
    # « ··[K]·LABEL·· »
    column=$((6 + width + 2))
    for i in "${!keys[@]}"; do
        ui_key "${keys[i]}"
        if ((UI_WIDTH - column >= 30)); then
            ui_pad "${labels[i]}" "$width"
            ui_glue "${notes[i]}"
            ui_wrap "$UI_GLUED" $((UI_WIDTH - column))
            printf -v indent '%*s' "$column" ''
            first=1
            for part in "${UI_LINES[@]}"; do
                part=${part//$'\x01'/ }
                if ((first)); then
                    printf '  %s %s  %s%s%s\n' "$UI_KEY" "$UI_PAD" "$C_GREY" "$part" "$C_RESET"
                    first=0
                else
                    printf '%s%s%s%s\n' "$indent" "$C_GREY" "$part" "$C_RESET"
                fi
            done
            continue
        fi
        ui_print "  $UI_KEY ${labels[i]}"
        ui_glue "${notes[i]}"
        ui_wrap "$UI_GLUED" $((UI_WIDTH - 6))
        for part in "${UI_LINES[@]}"; do printf '      %s%s%s\n' "$C_GREY" "${part//$'\x01'/ }" "$C_RESET"; done
    done
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

# ui_pause [next [tight]] — after an action: « Enter ↵ back · Q quit » (next:
# « Enter ↵ continue », more screens follow). tight: right under the last
# line, without an empty line first (under a QR code that fills the window).
# Status 1 for Q.
# shellcheck disable=SC2120 # « next » comes from pause_next (lib/common.sh)
ui_pause() {
    local answer text
    ((INTERACTIVE)) || return 0
    if [[ ${1-} == next ]]; then text=$(t 'Enter ↵ continue · Q quit'); else text=$(t 'Enter ↵ back · Q quit'); fi
    if [[ ${2-} != tight ]]; then echo; fi
    IFS= read -r -p "  $C_GREY$text$C_RESET " answer || {
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
# « ✔ »: it is done), good (green, « ● »: a card, a summary before an
# action), warn (yellow), info (pink). Long lines are wrapped.
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

# ui_box_fields LEVEL TITLE — the fields added with ui_field_add, in a frame
# (a summary, the card of a client): names in grey, values aligned. A value
# too long for the frame goes on to the next lines, under itself; in a frame
# too narrow for both, each value goes under its name.
ui_box_fields() {
    local level=$1 title=$2 i width=0 room part name indent
    local -a lines=()
    for i in "${!UI_FIELD_LABELS[@]}"; do
        ui_len "${UI_FIELD_LABELS[i]}"
        if ((UI_LEN > width)); then width=$UI_LEN; fi
    done
    # the frame takes the width of the screen at most: 2 + « │ » + space on
    # each side
    room=$((UI_WIDTH - 2 - 4 - width - 2))
    for i in "${!UI_FIELD_LABELS[@]}"; do
        ui_pad "${UI_FIELD_LABELS[i]}" "$width"
        name="$C_GREY$UI_PAD$C_RESET  "
        if ((room >= 12)); then
            printf -v indent '%*s' $((width + 2)) ''
            ui_wrap "${UI_FIELD_VALUES[i]}" "$room"
        else
            lines+=("$C_GREY${UI_FIELD_LABELS[i]}$C_RESET")
            name="  "
            indent="  "
            ui_wrap "${UI_FIELD_VALUES[i]}" $((UI_WIDTH - 2 - 4 - 2))
        fi
        for part in "${UI_LINES[@]}"; do
            lines+=("$name$part")
            name=$indent
        done
    done
    UI_FIELD_LABELS=()
    UI_FIELD_VALUES=()
    ui_box "$level" "$title" "${lines[@]}"
}

# --- Navigation ------------------------------------------------------------------

# ui_top PART… — top of a menu: header, line, where we are
ui_top() {
    ui_screen
    ui_header
    ui_rule
    ui_crumbs "$@"
    echo
}

# ui_quit — leaves seedtunnel, from anywhere in the menus: an action runs in a
# subshell, which only passes the request on (UI_QUIT_STATUS) to the menu that
# started it
ui_quit() {
    if ((BASH_SUBSHELL > 0)); then exit "$UI_QUIT_STATUS"; fi
    echo
    say 'See you soon!'
    echo
    exit 0
}

# ui_action COMMAND [ARGUMENTS…] — an action of a menu, in a subshell. If it
# fails (die, unexpected error), its message stays on the screen and Enter
# goes back to the menu, instead of leaving seedtunnel.
# Always call it on its own, never in an « if », « || » or « && »: bash would
# then ignore « set -e » inside the action too, which would go on after an
# error.
ui_action() {
    local status
    subshell_run "$@"
    status=$SUBSHELL_STATUS
    case $status in
        0) return 0 ;;
        "$UI_QUIT_STATUS") ui_quit ;;
        # end of the input (Ctrl+D)
        130) exit 130 ;;
    esac
    # its message is on the screen
    if ! ui_pause; then ui_quit; fi
}

# danger TITLE LINE… — before a question that cannot be undone: a red frame in
# the menus, the lines as warnings for the commands (texts already translated)
danger() {
    local title=$1 line
    shift
    if ((INTERACTIVE)); then
        ui_box bad "$title" "$@"
        echo
        return 0
    fi
    for line in "$@"; do printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$line" >&2; done
}
