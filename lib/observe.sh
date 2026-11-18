#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Read-only observations. Callers declare associative result arrays; no cache,
# translated text, feature state or server changes. Internal names use _observe_.

# service_observe UNIT RESULT — one systemd read for runtime and boot state.
# A failed/incomplete query is unknown, not a stopped or missing service.
service_observe() {
    local _observe_text _observe_line _observe_load="" _observe_active="" _observe_boot="" _observe_status=0
    local -n _observe_result=$2
    _observe_result=([state]=unknown [boot]=unknown)
    _observe_text=$(systemctl show -p LoadState -p ActiveState -p UnitFileState -- "$1" 2>/dev/null) || _observe_status=$?
    while IFS= read -r _observe_line; do
        case $_observe_line in
            LoadState=*) _observe_load=${_observe_line#*=} ;;
            ActiveState=*) _observe_active=${_observe_line#*=} ;;
            UnitFileState=*) _observe_boot=${_observe_line#*=} ;;
        esac
    done <<<"$_observe_text"
    if [[ $_observe_load == not-found ]]; then
        _observe_result[state]=missing
        return 0
    elif ((_observe_status)); then
        return 0
    elif [[ $_observe_load == loaded || $_observe_load == masked ]]; then
        case $_observe_active in
            active | reloading) _observe_result[state]=active ;;
            inactive | failed | activating | deactivating | maintenance) _observe_result[state]=stopped ;;
        esac
    fi
    case $_observe_boot in
        enabled | enabled-runtime | static | indirect | generated | transient | alias) _observe_result[boot]=on ;;
        disabled | masked | masked-runtime | linked | linked-runtime) _observe_result[boot]=off ;;
    esac
}

# http_access_state CODE MODE — MODE is protected (no credentials) or login.
# A 401 only proves an authentication barrier; 409 with credentials proves
# the RPC session handshake, not that an API method or a download works.
http_access_state() {
    case "$2:$1" in
        protected:401) printf '%s' protected ;;
        login:409) printf '%s' handshake ;;
        login:401) printf '%s' refused ;;
        *:502 | *:504) printf '%s' upstream_unreachable ;;
        *: | *:000) printf '%s' unreachable ;;
        *) printf '%s' unexpected ;;
    esac
}
