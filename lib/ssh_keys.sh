#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared SSH key formats, fingerprints and keypair creation.
# No administrator/SFTP policy or feature state. Callers own temporary files.

# ssh_keys_openssh < TEXT — the public keys of TEXT, one OpenSSH line each:
# OpenSSH lines as they are, the blocks « ---- BEGIN SSH2 PUBLIC KEY ---- »
# (what PuTTYgen saves) turned into OpenSSH lines by ssh-keygen, with their
# comment (ssh-keygen drops it: the name of the key in the lists). Status 2: a
# block that cannot be read; 3: a private key (nothing printed after it).
ssh_keys_openssh() {
    local line block="" in_block=0 tmp converted comment=""
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if ((in_block)); then
            block+="$line"$'\n'
            if [[ $line =~ ^Comment:\ *\"?([^\"]*)\"?$ ]]; then comment=${BASH_REMATCH[1]//[^[:alnum:]@._:+=-]/-}; fi
            if [[ $line == "---- END SSH2 PUBLIC KEY ----" ]]; then
                tmp=$(mktemp) || return 2
                printf '%s' "$block" >"$tmp"
                # its first line (no « | head »: pipefail)
                converted=$(ssh-keygen -i -m RFC4716 -f "$tmp" 2>/dev/null) || converted=""
                converted=${converted%%$'\n'*}
                rm -f "$tmp"
                [[ $converted == ssh-* || $converted == ecdsa-* || $converted == sk-* ]] || return 2
                if [[ -n $comment && $converted != *" "*" "* ]]; then converted+=" $comment"; fi
                printf '%s\n' "$converted"
                in_block=0
                block=""
                comment=""
            fi
            continue
        fi
        case $line in
            "---- BEGIN SSH2 PUBLIC KEY ----")
                in_block=1
                block="$line"$'\n'
                ;;
            *"PRIVATE KEY"* | PuTTY-User-Key-File*) return 3 ;;
            "" | \#*) ;;
            *) printf '%s\n' "$line" ;;
        esac
    done
    ((!in_block)) || return 2
}

# ssh_key_data LINE — what makes a key itself (its base64 part): the same
# key with another comment is the same key
ssh_key_data() {
    local word
    local -a words=()
    read -ra words <<<"$1"
    for word in "${words[@]}"; do
        if [[ $word == AAAA* ]]; then
            printf '%s' "$word"
            return 0
        fi
    done
    printf '%s' "$1"
}

# ssh_key_known SAVED LINE [LINES…] — the key of LINE is already in SAVED (the
# keys saved, as text), or among the other LINES given
ssh_key_known() {
    local data other
    data=$(ssh_key_data "$2")
    if grep -qF -- "$data" <<<"$1"; then return 0; fi
    shift 2
    for other in "$@"; do
        [[ $(ssh_key_data "$other") != "$data" ]] || return 0
    done
    return 1
}

# ssh_pasted_block FIRST_LINE — a block of PuTTYgen pasted in a question: its
# first line was read, the others are still waiting. All of it, as OpenSSH
# lines (status of ssh_keys_openssh).
ssh_pasted_block() {
    local pasted=$1$'\n' line
    while IFS= read -r -t 1 line; do
        pasted+="$line"$'\n'
        [[ ${line%$'\r'} != "---- END SSH2 PUBLIC KEY ----" ]] || break
    done
    ssh_keys_openssh <<<"$pasted"
}

# Fingerprint of the key of the server, shown by SFTP programs at the first
# connection (e.g. « SHA256:szUj…NT8 ED25519 »): empty if not found
ssh_host_key_fingerprint() {
    local file=$1
    [[ -r $file ]] || return 0
    ssh-keygen -l -E sha256 -f "$file" 2>/dev/null | awk '{ gsub(/[()]/, "", $NF); print $2, $NF }' || true
}

# Fingerprint in the format of WinSCP addresses: « ssh-ed25519-<SHA-256> »,
# base64 padded with « = », with « - » instead of « + » and « _ » instead of
# « / » (https://winscp.net/eng/docs/session_url)
ssh_host_key_fingerprint_url() {
    local file=$1 fingerprint
    [[ -r $file ]] || return 0
    fingerprint=$(ssh-keygen -l -E sha256 -f "$file" 2>/dev/null | awk '{ print $2 }' || true)
    fingerprint=${fingerprint#SHA256:}
    [[ -n $fingerprint ]] || return 0
    while ((${#fingerprint} % 4)); do fingerprint+="="; done
    fingerprint=${fingerprint//+/-}
    fingerprint=${fingerprint//\//_}
    printf 'ssh-ed25519-%s' "$fingerprint"
}

# ssh_key_pair_create DIRECTORY COMMENT — caller owns a private temporary
# directory and its cleanup trap. Status is preserved; no sharing or import.
ssh_key_pair_create() {
    (umask 077 && ssh-keygen -q -t ed25519 -N '' -C "$2" -f "$1/key" \
        && puttygen "$1/key" -O private -o "$1/key.ppk" --ppk-param version=2) </dev/null >>"$APP_LOG" 2>&1
}
