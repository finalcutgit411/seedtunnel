#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared network helpers: validation, local addresses, routes and port checks.
# Loaded after common.sh and before feature modules; sourcing has no side effects.
# Query helpers print their result; predicates return 0/1. nft_delete_table
# changes nftables only when called. Logging and translation use common/i18n.

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

# Domain name in lower case, or an IPv4 address. Predicate: 0 valid, 1 invalid.
# Keeps the existing policy: no single label, trailing dot or upper-case name.
is_domain_or_ipv4() {
    [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || is_ipv4 "$1"
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
    local_ipv4
}

# IPv4 address the server goes out with, read on the server itself (the
# route to the Internet: nothing is sent): its public address on a VPS, its
# local one behind a box. Empty if none, never a failure.
local_ipv4() {
    local ip
    ip=$({ ip -4 route get 1.1.1.1 2>/dev/null || true; } \
        | awk '!found { for (i = 1; i < NF; i++) if ($i == "src") { print $(i+1); found = 1 } }')
    if is_ipv4 "$ip"; then printf '%s' "$ip"; fi
}

# Addresses of the server itself, IPv4 and IPv6 (one per line, without /prefix)
network_local_addresses() { ip -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }' || true; }

# Is the address $1 the server itself (localhost or one of its addresses)?
network_is_local_address() {
    [[ $1 == 127.* || $1 == ::1 ]] || grep -qxF -- "$1" <<<"$(network_local_addresses)"
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

# listening_programs < LINES OF « ss -p » → « apache2 (80, 443), … »: each
# program and its ports (docker-proxy said as a container of Docker), or « a
# program not named » when ss gives no name
listening_programs() {
    local line name list=""
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        name=${line%% (*}
        if [[ $name == docker-proxy ]]; then line="$(t 'a container of Docker') ${line#"$name" }"; fi
        list+="${list:+, }$line"
    done < <(awk '{
        n = split($4, a, ":"); port = a[n]; rest = $0
        while (match(rest, /\("[^"]+"/)) {
            name = substr(rest, RSTART + 2, RLENGTH - 3); rest = substr(rest, RSTART + RLENGTH)
            if (!((name, port) in seen)) {
                seen[name, port] = 1
                if (name in ports) ports[name] = ports[name] ", " port; else ports[name] = port
            }
        }
    } END { for (name in ports) print name " (" ports[name] ")" }' | LC_ALL=C sort)
    printf '%s' "${list:-$(t 'a program not named')}"
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

# DNS observations shared by site orchestration and the seedbox.
dns_ipv4_addresses() {
    dig +short +time=3 +tries=2 A "$1" @9.9.9.9 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' || true
}

dns_points_here() {
    [[ -n $2 ]] && grep -qxF "$2" <<<"$(dns_ipv4_addresses "$1")"
}
