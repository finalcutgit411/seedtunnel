#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Pure SFTP profile renderers. Callers supply validated account/host/port,
# site label, fingerprint and optional key basename; no file or feature state.

# Address to paste into WinSCP, with the fingerprint of the server when known:
# WinSCP then checks the key of the server by itself, without a question
sftp_winscp_url() {
    local user=$1 host=$2 port=$3 fingerprint=$4
    if [[ -n $fingerprint ]]; then
        printf 'sftp://%s;fingerprint=%s@%s:%s/' "$user" "$fingerprint" "$host" "$port"
    else
        printf 'sftp://%s@%s:%s/' "$user" "$host" "$port"
    fi
}

# Site to import into FileZilla (File → Import…). Logontype 2: the password is
# asked at connection time, it is not in the file.
sftp_filezilla_site() {
    local user=$1 host=$2 port=$3 name=$4
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<FileZilla3>
    <Servers>
        <Server>
            <Host>$host</Host>
            <Port>$port</Port>
            <Protocol>1</Protocol>
            <Type>0</Type>
            <User>$user</User>
            <Logontype>2</Logontype>
            <TimezoneOffset>0</TimezoneOffset>
            <PasvMode>MODE_DEFAULT</PasvMode>
            <MaximumMultipleConnections>0</MaximumMultipleConnections>
            <EncodingType>Auto</EncodingType>
            <BypassProxy>0</BypassProxy>
            <Name>$name</Name>
            <Comments />
            <Colour>0</Colour>
            <LocalDir />
            <RemoteDir />
            <SyncBrowsing>0</SyncBrowsing>
            <DirectoryComparison>0</DirectoryComparison>
        </Server>
    </Servers>
</FileZilla3>
EOF
}

# Site to import into WinSCP (login window → Tools → Import Sites → INI file):
# a WinSCP.ini that holds this site only. Sites already saved are kept (same
# name: WinSCP adds a number). No password in it: it is asked at connection
# time. Protocol not written: SFTP is the default. Windows line ends, as in
# the files WinSCP writes. The name of the site is escaped as WinSCP does it
# (« %20 » for a space).
# With it, the fingerprint of the server: WinSCP imports it with the site into
# the keys it knows, and accepts a fingerprint there instead of a whole key.
# It then checks the server by itself, without a question at the first
# connection (as with the address of winscp_url).
# With a key made by seedtunnel: the site uses it, from the .ssh folder of the
# personal folder (%USERPROFILE%, replaced by WinSCP at connection time;
# written « %25 » and « %5C » for « % » and « \ », as in WinSCP.ini).
sftp_winscp_site() {
    local user=$1 host=$2 port=$3 name=$4 fingerprint=$5 key_name=$6
    printf '[Sessions\\%s]\r\nHostName=%s\r\nPortNumber=%s\r\nUserName=%s\r\n' \
        "${name// /%20}" "$host" "$port" "$user"
    if [[ -n $key_name ]]; then
        printf 'PublicKeyFile=%%25USERPROFILE%%25%%5C.ssh%%5C%s\r\n' "$key_name"
    fi
    if [[ -n $fingerprint ]]; then
        printf '\r\n[SshHostKeys]\r\nssh-ed25519@%s:%s=%s\r\n' "$port" "$host" "${fingerprint%%=*}"
    fi
}
