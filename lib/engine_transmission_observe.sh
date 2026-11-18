#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Transmission observations only. Load after its adapter and common/observe.
# Result arrays belong to callers; _tr_* names are reserved internally.
# No seedbox state, translated messages, cached results or system mutations.

transmission_runtime_state() {
    local _tr_status=0
    transmission_is_active 2>/dev/null || _tr_status=$?
    case $_tr_status in
        0) printf '%s' active ;;
        3 | 4) printf '%s' not_running ;;
        *) printf '%s' unknown ;;
    esac
}

transmission_inspect() {
    case $1 in
        settings) transmission_inspect_settings "$2" "$3" ;;
        apparmor) transmission_inspect_apparmor "$2" "$3" ;;
        umask) transmission_inspect_umask "$3" ;;
        watch) transmission_inspect_watch "$2" "$3" ;;
        *)
            local -n _tr_inspect_invalid=$3
            _tr_inspect_invalid=([state]=unsupported)
            ;;
    esac
}

transmission_inspect_settings() {
    local -n _tr_settings_result=$2
    _tr_settings_result=([state]=unknown [scripts]="")
    local _tr_file _tr_json _tr_scripts _tr_mode _tr_dir_mode _tr_mounts _tr_data
    _tr_file=$(transmission_settings_file 2>/dev/null) || return 0
    [[ -f $_tr_file ]] || return 0
    # Read as the engine account, not as root through an engine-owned path.
    _tr_json=$(transmission_settings_read "$_tr_file" 2>/dev/null) || return 0
    _tr_scripts=$(jq -ser 'if length == 1 and (.[0] | type) == "object" then
        .[0] | [to_entries[] | select((.key | test("^script-torrent-.*-enabled$")) and .value == true) | .key] | join(", ")
        else error("invalid settings") end' <<<"$_tr_json" 2>/dev/null) || return 0
    _tr_settings_result[scripts]=$_tr_scripts
    if [[ -n $_tr_scripts ]]; then
        _tr_settings_result[state]=scripts
        return 0
    fi
    _tr_mode=$(stat -c %a -- "$_tr_file" 2>/dev/null) || return 0
    _tr_dir_mode=$(stat -c %a -- "$TRANSMISSION_STATE_DIR" 2>/dev/null) || return 0
    [[ $_tr_mode =~ ^[0-7]{1,4}$ && $_tr_dir_mode =~ ^[0-7]{1,4}$ ]] || return 0
    if (((8#$_tr_mode | 8#$_tr_dir_mode) & 8#7)); then
        _tr_settings_result[state]=public
        return 0
    fi
    if ! _tr_mounts=$(transmission_mountinfo); then
        if [[ $(transmission_runtime_state) == not_running ]]; then _tr_settings_result[state]=ok; fi
        return 0
    fi
    # A kernel mountinfo view has a root mount; empty/malformed data is not a
    # proof of confinement. A stopped engine has only its settings checked.
    awk 'NF >= 10 && $5 == "/" { found=1 } END { exit !found }' <<<"$_tr_mounts" || return 0
    _tr_data=$(readlink -f -- "$1" 2>/dev/null) || _tr_data=$1
    if mount_noexec "$_tr_data" <<<"$_tr_mounts"; then _tr_settings_result[state]=ok; else _tr_settings_result[state]=executable; fi
}

transmission_inspect_apparmor() {
    local -n _tr_apparmor_result=$2
    _tr_apparmor_result=([state]=unknown [refused]="")
    local _tr_profile _tr_expected _tr_actual _tr_since _tr_refused
    if [[ ! -e $TRANSMISSION_APPARMOR_PROFILE && ! -L $TRANSMISSION_APPARMOR_PROFILE ]]; then
        _tr_apparmor_result[state]=not_applicable
        return 0
    fi
    _tr_profile=$(cat "$TRANSMISSION_APPARMOR_PROFILE" 2>/dev/null) || return 0
    if [[ $_tr_profile != *local/transmission-daemon* ]]; then
        _tr_apparmor_result[state]=not_applicable
        return 0
    fi
    _tr_expected=$(transmission_apparmor_generate "$1") || return 0
    if [[ ! -e $TRANSMISSION_APPARMOR_LOCAL && ! -L $TRANSMISSION_APPARMOR_LOCAL ]]; then
        _tr_apparmor_result[state]=rules
        return 0
    fi
    _tr_actual=$(cat "$TRANSMISSION_APPARMOR_LOCAL" 2>/dev/null) || return 0
    if [[ $_tr_expected != "$_tr_actual" ]]; then
        _tr_apparmor_result[state]=rules
        return 0
    fi
    _tr_since=$(stat -c %Y "$TRANSMISSION_APPARMOR_LOCAL" 2>/dev/null) || return 0
    [[ $_tr_since =~ ^[0-9]+$ ]] || return 0
    if ! _tr_refused=$(
        set -o pipefail
        journalctl -k -b --since "@$_tr_since" --no-pager 2>/dev/null \
            | awk '/apparmor="DENIED".*profile="transmission-daemon"/ { n++ } END { print n+0 }'
    ); then return 0; fi
    _tr_apparmor_result[refused]=$_tr_refused
    if ((_tr_refused)); then _tr_apparmor_result[state]=denied; else _tr_apparmor_result[state]=ok; fi
}

# Empty if no process is readable. The inspector separately establishes
# whether this means stopped or an unavailable observation of a live engine.
transmission_process_umask() {
    local _tr_pid
    _tr_pid=$(systemctl show -p MainPID --value transmission-daemon 2>/dev/null) || return 0
    [[ $_tr_pid =~ ^[1-9][0-9]*$ ]] || return 0
    awk '$1 == "Umask:" { print $2 }' "/proc/$_tr_pid/status" 2>/dev/null || true
}

transmission_inspect_umask() {
    local -n _tr_umask_result=$1
    local _tr_umask
    _tr_umask_result=([state]=unknown [umask]="")
    _tr_umask=$(transmission_process_umask)
    if [[ $_tr_umask =~ ^[0-7]{1,4}$ ]]; then
        _tr_umask_result[umask]=$_tr_umask
        if (((8#$_tr_umask & 8#2) == 0)); then _tr_umask_result[state]=unsafe; else _tr_umask_result[state]=ok; fi
    elif [[ $(transmission_runtime_state) == not_running ]]; then
        _tr_umask_result[state]=not_running
    fi
}

transmission_inspect_watch() {
    local -n _tr_watch_result=$2
    local _tr_watch="$1/watch" _tr_file _tr_metadata _tr_mode _tr_owner _tr_group _tr_count=0
    _tr_watch_result=([state]=unknown [count]=0 [path]="$_tr_watch")
    [[ -d $_tr_watch && -r $_tr_watch && -x $_tr_watch ]] || return 0
    _tr_watch_result[state]=ok
    for _tr_file in "$_tr_watch"/*.torrent; do
        [[ -f $_tr_file && ! -L $_tr_file ]] || continue
        if ! _tr_metadata=$(stat -c '%a %U %G' "$_tr_file" 2>/dev/null); then
            _tr_watch_result[state]=unknown
            continue
        fi
        read -r _tr_mode _tr_owner _tr_group <<<"$_tr_metadata"
        if [[ ! $_tr_mode =~ ^[0-7]{1,4}$ || -z $_tr_owner || -z $_tr_group ]]; then
            _tr_watch_result[state]=unknown
            continue
        fi
        _tr_mode=000$_tr_mode
        _tr_mode=${_tr_mode: -3}
        if ((${_tr_mode:2:1} & 4)) || { [[ $_tr_group == "$(transmission_group)" ]] && ((${_tr_mode:1:1} & 4)); } \
            || { [[ $_tr_owner == "$(transmission_account)" ]] && ((${_tr_mode:0:1} & 4)); }; then continue; fi
        _tr_count=$((_tr_count + 1))
    done
    _tr_watch_result[count]=$_tr_count
}

transmission_probe() {
    case $1 in
        rpc) transmission_probe_rpc "$2" ;;
        peer) transmission_probe_peer "$2" ;;
        *)
            local -n _tr_probe_invalid=$2
            _tr_probe_invalid=([state]=unsupported)
            ;;
    esac
}

transmission_probe_rpc() {
    local -n _tr_rpc_result=$1
    local _tr_runtime _tr_code _tr_status=0
    _tr_rpc_result=([state]=unknown [http_code]="" [transport_status]="")
    _tr_runtime=$(transmission_runtime_state)
    if [[ $_tr_runtime != active ]]; then
        _tr_rpc_result[state]=$_tr_runtime
        return 0
    fi
    # No credentials, no API method and no proxy or redirect out of loopback.
    _tr_code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 \
        "http://127.0.0.1:$TRANSMISSION_RPC_PORT/transmission/rpc" 2>/dev/null) || _tr_status=$?
    _tr_rpc_result[transport_status]=$_tr_status
    if [[ $_tr_code =~ ^[0-9]{3}$ ]]; then _tr_rpc_result[http_code]=$_tr_code; fi
    if ((_tr_status)) || [[ $_tr_code == 000 || -z $_tr_code ]]; then
        _tr_rpc_result[state]=unreachable
    else
        case $_tr_code in
            401) _tr_rpc_result[state]=auth_required ;;
            409) _tr_rpc_result[state]=session_required ;;
            *) _tr_rpc_result[state]=unexpected ;;
        esac
    fi
}

transmission_probe_peer() {
    local -n _tr_peer_result=$1
    local _tr_runtime _tr_answer
    _tr_peer_result=([state]=unknown [port]="$TORRENT_PORT")
    _tr_runtime=$(transmission_runtime_state)
    if [[ $_tr_runtime != active ]]; then
        _tr_peer_result[state]=$_tr_runtime
        return 0
    fi
    _tr_answer=$(curl -4 -fsS --max-time 20 "https://portcheck.transmissionbt.com/$TORRENT_PORT" 2>/dev/null) || return 0
    case $_tr_answer in
        1) _tr_peer_result[state]=open ;;
        0) _tr_peer_result[state]=closed ;;
    esac
}
