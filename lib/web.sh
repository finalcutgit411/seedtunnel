#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared web resources and application. Load after common/network/i18n/tls.
# Renderers are trusted internal functions, called with DOMAIN CERTIFICATE.
# web_https_apply DOMAIN POLICY SERVER RESULT_VARIABLE RENDERER RETRY_COMMAND
# updates only the caller-owned certificate variable via a nameref.

WEB_SSL_DIR="$APP_STATE_DIR/ssl"
NGINX_SITE="/etc/nginx/sites-available/seedtunnel"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/seedtunnel"
NGINX_DEFAULT_SITE="/etc/nginx/sites-enabled/default"
NGINX_DEFAULT_SOURCE="/etc/nginx/sites-available/default"
LETSENCRYPT_WEBROOT="/var/www/letsencrypt"
LETSENCRYPT_CERT_NAME="seedtunnel"
LETSENCRYPT_ROOT="/etc/letsencrypt"
LETSENCRYPT_DIR="$LETSENCRYPT_ROOT/live/$LETSENCRYPT_CERT_NAME"

web_check_ports() {
    local out ports programs title needs
    out=$(ss -Hltnp '( sport = :80 or sport = :443 )' 2>/dev/null || true)
    # each listening line: nginx on one port does not cover another program on the other
    out=$(grep -v nginx <<<"$out" || true)
    [[ -n $out ]] || return 0
    ports=$(awk '{ n = split($4, a, ":"); print a[n] }' <<<"$out" | LC_ALL=C sort -nu | paste -sd ' ')
    programs=$(listening_programs <<<"$out")
    case $ports in
        80) title=$(t 'Port %s already taken' 80) ;;
        443) title=$(t 'Port %s already taken' 443) ;;
        *) title=$(t 'Ports 80, 443 already taken') ;;
    esac
    if [[ ${1-} == links ]]; then
        needs=$(t 'The site of the links needs them: nothing was changed.')
    else
        needs=$(t 'The seedbox needs them for its web interface: nothing was changed.')
    fi
    refuse "$title" \
        "$(t 'Another program uses them: %s.' "$programs")" \
        "$needs" \
        "$(t 'To go on: stop this program and keep it from starting again (for example: sudo systemctl disable --now apache2), then start again.')"
}

web_letsencrypt_delete() {
    command -v certbot >/dev/null || return 0
    [[ -e $LETSENCRYPT_ROOT/renewal/$LETSENCRYPT_CERT_NAME.conf ]] || return 0
    log_run "Deleting the Let's Encrypt certificate" certbot delete --cert-name "$LETSENCRYPT_CERT_NAME" --non-interactive
}

web_acme_request() {
    local domain=$1 server=$2
    local label=""
    local -a extra=()
    install -d -m 755 "$LETSENCRYPT_WEBROOT"
    # Existing certificate for another name or another server: start over
    if [[ -e $LETSENCRYPT_DIR/cert.pem ]] && ! tls_acme_usable "$LETSENCRYPT_DIR/cert.pem" "$domain" "$server"; then
        certbot delete --cert-name "$LETSENCRYPT_CERT_NAME" --non-interactive >>"$APP_LOG" 2>&1 || true
    fi
    if [[ $server == staging ]]; then
        extra=(--test-cert)
        label=" $(t '(test server)')"
    fi
    printf '  %s… ' "$(t "Requesting the Let's Encrypt certificate%s for %s" "$label" "$domain")"
    log_title "Let's Encrypt certificate for %s" "$domain"
    if certbot certonly --webroot -w "$LETSENCRYPT_WEBROOT" --cert-name "$LETSENCRYPT_CERT_NAME" -d "$domain" \
        --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring \
        --deploy-hook "systemctl reload nginx" "${extra[@]}" >>"$APP_LOG" 2>&1; then
        printf '%s%s%s\n' "$C_GREEN" "$(t 'ok')" "$C_RESET"
        return 0
    fi
    printf '%s%s%s\n' "$C_RED" "$(t 'failed')" "$C_RESET"
    return 1
}

nginx_default_site_untouched() {
    local package md5
    [[ -L $NGINX_DEFAULT_SITE && $(readlink -f "$NGINX_DEFAULT_SITE") == "$(readlink -f "$NGINX_DEFAULT_SOURCE")" ]] || return 1
    package=$(dpkg-query -S "$NGINX_DEFAULT_SOURCE" 2>/dev/null | cut -d: -f1 | head -n 1)
    [[ -n $package ]] || return 1
    md5=$(dpkg-query -W -f='${Conffiles}\n' "$package" 2>/dev/null | awk -v file="$NGINX_DEFAULT_SOURCE" '$1 == file { print $2 }')
    [[ -n $md5 && $(md5sum <"$NGINX_DEFAULT_SOURCE") == "$md5 "* ]]
}

nginx_default_site_off() {
    local note="$APP_STATE_DIR/nginx-default-kept"
    if [[ ! -e $NGINX_DEFAULT_SITE && ! -L $NGINX_DEFAULT_SITE ]]; then
        rm -f "$note"
    elif nginx_default_site_untouched; then
        pending_set nginx
        rm -f "$NGINX_DEFAULT_SITE" "$note"
    elif [[ ! -e $note ]]; then
        warn 'The site « default » of nginx was changed: seedtunnel leaves it on (%s).' "$NGINX_DEFAULT_SITE"
        : >"$note"
    fi
}

web_nginx_apply() {
    local renderer=$1 domain=$2 certificate=$3 _web_nginx_changed=0
    if write_if_changed_pending nginx "$NGINX_SITE" 644 root:root "$renderer" "$domain" "$certificate"; then _web_nginx_changed=1; fi
    if [[ ! -L $NGINX_SITE_LINK || ! $NGINX_SITE_LINK -ef $NGINX_SITE ]]; then
        pending_set nginx
        # -T prevents a wrong symlink to a directory from writing inside it.
        ln -sfnT -- "$NGINX_SITE" "$NGINX_SITE_LINK"
    fi
    nginx_default_site_off
    if ((_web_nginx_changed)) || pending nginx || ! systemctl is-active --quiet nginx; then
        if ! pending nginx; then pending_set nginx; fi
        run 'Checking the nginx configuration' nginx -t
        run 'Reloading nginx' systemctl reload-or-restart nginx
    fi
    # A successful reload alone does not confirm activity or boot enablement.
    unit_ensure_on "$(t 'Enabling %s at boot' nginx)" nginx
    if ! systemctl is-active --quiet nginx || ! systemctl is-enabled --quiet nginx; then
        pending_set nginx
        die 'nginx activation could not be confirmed; pending state kept. Run seedtunnel apply again.'
    fi
    if pending nginx; then pending_clear nginx; fi
}

web_https_apply() {
    local domain=$1 policy=$2 server=$3 renderer=$5 retry=$6
    local -n _web_certificate=$4
    local want=0 ip
    tls_selfsigned_ensure "$domain" "$WEB_SSL_DIR"
    if is_ipv4 "$domain" || [[ $policy == no ]]; then
        _web_certificate=selfsigned
    elif tls_acme_usable "$LETSENCRYPT_DIR/cert.pem" "$domain" "$server"; then
        # certificate already in place (run again, restore): nothing to request
        _web_certificate=$(tls_certificate_mode "$server")
    else
        if [[ $policy == yes ]]; then
            want=1
        else
            ip=$(public_ipv4)
            if dns_points_here "$domain" "$ip"; then
                want=1
            else
                warn '"%s" does not point to this server (%s): self-signed certificate.' "$domain" "$ip"
            fi
        fi
        if ((want)); then
            # nginx must already answer on port 80 for the validation
            if [[ $_web_certificate != selfsigned ]] && ! tls_certificate_matches_name "$LETSENCRYPT_DIR/cert.pem" "$domain"; then _web_certificate=selfsigned; fi
            web_nginx_apply "$renderer" "$domain" "$_web_certificate"
            if web_acme_request "$domain" "$server"; then
                _web_certificate=$(tls_certificate_mode "$server")
                ok "Let's Encrypt certificate installed, renewed automatically."
            elif tls_acme_usable "$LETSENCRYPT_DIR/cert.pem" "$domain" "$server"; then
                _web_certificate=$(tls_certificate_mode "$server")
                warn "Let's Encrypt did not answer, the existing certificate (still valid) is kept."
            else
                _web_certificate=selfsigned
                warn "Let's Encrypt did not issue a certificate: the self-signed one stays in place."
                text letsencrypt_failed_help "$retry"
            fi
        else
            _web_certificate=selfsigned
        fi
    fi
    web_nginx_apply "$renderer" "$domain" "$_web_certificate"
    # automatic renewal (installed with the certbot package), at boot too
    if [[ $_web_certificate != selfsigned ]]; then
        unit_ensure_on 'Enabling automatic renewal' certbot.timer
    fi
}
