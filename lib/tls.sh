#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# TLS primitives shared by sites. Load after common/network/i18n.
# Arguments are explicit; no seedbox or site state is read or modified.
# Sourcing has no side effects. Only tls_selfsigned_ensure writes files.

# tls_selfsigned_ensure DOMAIN DIRECTORY: create/reuse the fallback certificate.
tls_selfsigned_ensure() {
    local domain=$1 directory=$2
    local san="DNS:$domain" check=""
    local -a req
    if is_ipv4 "$domain"; then san="IP:$domain"; fi
    install -d -m 700 "$directory"
    if [[ -s $directory/selfsigned.crt && -s $directory/selfsigned.key ]]; then
        if is_ipv4 "$domain"; then
            check=$(openssl x509 -in "$directory/selfsigned.crt" -noout -checkip "$domain" 2>/dev/null || true)
        else
            check=$(openssl x509 -in "$directory/selfsigned.crt" -noout -checkhost "$domain" 2>/dev/null || true)
        fi
        [[ $check == *"does match"* ]] && return 0
    fi
    req=(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650
        -subj "/CN=$domain" -addext "subjectAltName=$san"
        -keyout "$directory/selfsigned.key" -out "$directory/selfsigned.crt")
    # a fallback when Let's Encrypt fails for a domain name; with an IP
    # address, the certificate that was chosen
    if is_ipv4 "$domain"; then
        run 'Creating a self-signed certificate' "${req[@]}"
    else
        run 'Creating a self-signed certificate (fallback)' "${req[@]}"
    fi
}

# tls_certificate_fingerprint FILE: SHA-256 fingerprint, empty if unreadable.
tls_certificate_fingerprint() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true
}

# tls_certificate_matches_name FILE DOMAIN: predicate for a DNS name.
tls_certificate_matches_name() {
    local certificate=$1 domain=$2
    local check
    [[ -e $certificate ]] || return 1
    check=$(openssl x509 -in "$certificate" -noout -checkhost "$domain" 2>/dev/null || true)
    [[ $check == *"does match"* ]]
}

# tls_acme_usable FILE DOMAIN SERVER: name, validity >= 1 day and issuer kind.
tls_acme_usable() {
    local certificate=$1 domain=$2 server=$3
    local issuer
    tls_certificate_matches_name "$certificate" "$domain" || return 1
    openssl x509 -in "$certificate" -noout -checkend 86400 &>/dev/null || return 1
    issuer=$(openssl x509 -in "$certificate" -noout -issuer 2>/dev/null || true)
    if [[ $issuer == *STAGING* ]]; then [[ $server == staging ]]; else [[ $server == production ]]; fi
}

# tls_certificate_expiry FILE: YYYY-MM-DD, empty when unavailable.
tls_certificate_expiry() {
    local end
    end=$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    [[ -n $end ]] || return 0
    date -d "$end" +%F 2>/dev/null || true
}

# TLS lines of the HTTPS server (seedbox, or site of the links): the
# selected mode and explicit certificate directories.
tls_nginx_directives() {
    local mode=$1 selfsigned_dir=$2 acme_dir=$3
    local crt key
    if [[ $mode == selfsigned ]]; then
        crt="$selfsigned_dir/selfsigned.crt"
        key="$selfsigned_dir/selfsigned.key"
    else
        crt="$acme_dir/fullchain.pem"
        key="$acme_dir/privkey.pem"
    fi
    cat <<EOF
    ssl_certificate     $crt;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:seedtunnel:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
EOF
}

# HSTS header, starting with a new line: only with a real certificate,
# otherwise the browser would then refuse to let the user accept the security
# warning
tls_nginx_hsts() {
    local mode=$1
    if [[ $mode == letsencrypt ]]; then
        printf '\n    add_header Strict-Transport-Security "max-age=31536000" always;'
    fi
}

# ACME server kind to the persisted certificate mode.
tls_certificate_mode() {
    if [[ $1 == staging ]]; then printf staging; else printf letsencrypt; fi
}
