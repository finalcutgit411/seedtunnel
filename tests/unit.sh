#!/usr/bin/env bash
# =============================================================================
#  Unit tests of seedtunnel: no root and no server needed (run by
#  « make check », and on GitHub before the real installations of
#  tests/integration.sh). They replay bugs found in the past, so that they
#  never come back, and check a few helpers.
# =============================================================================
set -Euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

check() {
    local description=$1
    shift
    if "$@" >"$WORK/out" 2>&1; then
        printf '  \033[32m✔\033[0m %s\n' "$description"
        PASS=$((PASS + 1))
    else
        printf '  \033[31m✘ %s\033[0m\n' "$description"
        sed 's/^/      /' "$WORK/out"
        FAIL=$((FAIL + 1))
    fi
}

# Loads the libraries with their state and log in $WORK (each test runs in a
# subshell: « die » only leaves the test)
load() {
    APP_DIR=$ROOT
    # shellcheck source=lib/common.sh
    . "$ROOT/lib/common.sh"
    APP_STATE_DIR="$WORK/state"
    APP_LOG="$WORK/log"
    APP_LANG_FILE="$WORK/state/language"
    mkdir -p "$APP_STATE_DIR"
    local library
    for library in i18n ui vpn seedbox firewall share diskguard backup update doctor menu; do
        # shellcheck source=/dev/null
        . "$ROOT/lib/$library.sh"
    done
    i18n_load en
}

ME="$(id -un):$(id -gn)"

# --- vpn_sync: a refused configuration must not show « ok » --------------------

vpn_sync_reports_wg_failure() (
    load
    wg-quick() { printf '[Interface]\n'; }
    wg() {
        echo "wg: invalid configuration" >&2
        return 1
    }
    nft() { return 0; }
    local out
    if out=$(run 'Applying the configuration' vpn_sync 2>&1); then return 1; fi
    [[ $out == *failed* && $out != *"… ok"* ]]
)

vpn_sync_reports_strip_failure() (
    load
    wg-quick() { return 1; }
    wg() { return 0; }
    nft() { return 0; }
    ! (run 'Applying the configuration' vpn_sync) &>/dev/null
)

vpn_sync_ok_when_all_steps_work() (
    load
    wg-quick() { printf '[Interface]\n'; }
    # the configuration arrives as a file (process substitution), never on stdin
    wg() { [[ $1 == syncconf && -r $3 ]]; }
    nft() { return 0; }
    local out
    out=$(run 'Applying the configuration' vpn_sync 2>&1 </dev/null)
    [[ $out == *ok* ]]
)

# --- write_if_changed: never a half-written file ---------------------------------

write_keeps_file_when_generator_fails() (
    load
    printf 'old\n' >"$WORK/conf1"
    half_written() {
        printf 'half'
        return 1
    }
    local out
    if out=$(write_if_changed "$WORK/conf1" 644 "$ME" half_written 2>&1); then return 1; fi
    [[ $(<"$WORK/conf1") == old && $out == *"Cannot generate"* ]] && ! ls "$WORK"/conf1.?* &>/dev/null
)

write_keeps_file_when_replace_fails() (
    load
    printf 'old\n' >"$WORK/conf2"
    mv() { return 1; }
    local out
    if out=$(write_if_changed "$WORK/conf2" 644 "$ME" printf 'new\n' 2>&1); then return 1; fi
    [[ $(<"$WORK/conf2") == old && $out == *"Cannot replace"* ]] && ! ls "$WORK"/conf2.?* &>/dev/null
)

write_reports_changed_and_unchanged() (
    load
    rm -f "$WORK/conf3"
    write_if_changed "$WORK/conf3" 640 "$ME" printf 'a\n' || return 1
    [[ $(<"$WORK/conf3") == a && $(stat -c %a "$WORK/conf3") == 640 ]] || return 1
    ! write_if_changed "$WORK/conf3" 640 "$ME" printf 'a\n'
)

# --- one-time links ---------------------------------------------------------------

share_link_deleted_at_first_opening() (
    load
    command -v inotifywait >/dev/null || {
        echo "inotifywait missing (package inotify-tools)"
        return 1
    }
    local dir="$WORK/share/token1" pid i
    mkdir -p "$dir"
    echo data >"$dir/file.conf"
    bash -c "$SHARE_WATCHER" watcher "$dir/file.conf" 20 "$dir" "$WORK/mark" &
    pid=$!
    # opened again until the watcher reacts (it may take a moment to start)
    for i in $(seq 1 50); do
        [[ -e $dir/file.conf ]] || break
        cat "$dir/file.conf" &>/dev/null || true
        sleep 0.2
    done
    wait "$pid"
    [[ ! -e $dir && -e $WORK/mark ]]
)

share_link_expires() (
    load
    command -v inotifywait >/dev/null || return 1
    local dir="$WORK/share/token2"
    mkdir -p "$dir"
    echo data >"$dir/file.conf"
    rm -f "$WORK/mark2"
    bash -c "$SHARE_WATCHER" watcher "$dir/file.conf" 1 "$dir" "$WORK/mark2"
    [[ ! -e $dir && ! -e $WORK/mark2 ]]
)

# --- translations -------------------------------------------------------------------

french_message() (
    load
    i18n_load fr
    [[ $(t 'Client "%s" revoked: its key can no longer connect.' pc) == 'Client « pc » révoqué : sa clé ne peut plus se connecter.' ]]
)

unknown_message_stays_english() (
    load
    i18n_load fr
    [[ $(t 'A message nobody translated: %s' x) == 'A message nobody translated: x' ]]
)

language_detection() (
    load
    rm -f "$APP_LANG_FILE"
    [[ $(LANG=fr_FR.UTF-8 LC_ALL='' SEEDTUNNEL_LANG='' i18n_detect) == fr ]] || return 1
    [[ $(LANG=en_US.UTF-8 LC_ALL='' SEEDTUNNEL_LANG='' i18n_detect) == en ]] || return 1
    [[ $(LANG=fr_FR.UTF-8 LC_ALL='' SEEDTUNNEL_LANG=en i18n_detect) == en ]] || return 1
    echo fr >"$APP_LANG_FILE"
    [[ $(LANG=C LC_ALL='' SEEDTUNNEL_LANG='' i18n_detect) == fr ]]
)

long_texts_exist_in_french() (
    load
    i18n_load fr
    [[ $(text usage) == *"Utilisation :"* ]]
)

# --- helpers --------------------------------------------------------------------------

firewall_ports_parsing() (
    load
    local rules='tcp dport { 22, 2222 } accept
tcp dport { 80, 443 } accept
meta l4proto { tcp, udp } th dport 60000 accept
udp dport 51820 accept'
    [[ $(firewall_open_tcp_ports <<<"$rules" | tr '\n' ' ') == "22 80 443 2222 " ]]
)

lock_message_names_the_holder() (
    load
    APP_LOCK="$WORK/lock"
    (
        exec 9<>"$APP_LOCK"
        flock 9
        printf '%s %s %s\n' "$BASHPID" "$(date +%s)" pts/9 >"$APP_LOCK"
        sleep 3
    ) &
    sleep 0.5
    local out
    if out=$(take_lock 2>&1); then return 1; fi
    wait
    [[ $out == *"process "* && $out == *"pts/9"* && $out == *"kill "* ]]
)

# --- seedbox: changing the domain can always be cancelled ------------------------
# A seedbox with a valid Let's Encrypt certificate for old.example.org; the
# answers typed in the menu come from « answers », « confirm » answers no.

# The answers typed by the user, in order: answers "1" "" "b". A question asked
# once more than planned = a menu with no way out: the test fails. ask_back
# works as in the script: an empty answer goes back (status 1). The answers
# are in a file: the actions of the menus run in subshells (ui_action), and
# what they read must not be read again by the menu.
answers_load() {
    INTERACTIVE=1
    : >"$WORK/answers"
    exec 3>&2
    ask() {
        local _answer_line
        if [[ ! -s $WORK/answers ]]; then
            echo "the menu asks again: no way out of it" >&3
            exit 99
        fi
        IFS= read -r _answer_line <"$WORK/answers"
        sed -i 1d "$WORK/answers"
        printf -v "$1" '%s' "$_answer_line"
    }
    ask_back() {
        ask "$1"
        [[ -n ${!1} ]]
    }
    # the choice of a menu is an answer like the others
    ui_ask_choice() { ask "$1"; }
}

answers() { printf '%s\n' "$@" >"$WORK/answers"; }

domain_menu_load() {
    load
    answers_load
    SEEDBOX_DOMAIN=old.example.org
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_LETSENCRYPT=auto
    SEEDBOX_LETSENCRYPT_SERVER=production
    APPLIED=0
    confirm() { return 1; }
    clear() { :; }
    public_ipv4() { printf 203.0.113.10; }
    dns_ipv4_addresses() { if [[ $1 == *.example.org ]]; then printf 203.0.113.10; fi; }
    letsencrypt_usable() { [[ $SEEDBOX_DOMAIN == old.example.org && $1 == production ]]; }
    letsencrypt_expiry_date() { printf 2027-01-29; }
    seedbox_apply_https() { APPLIED=1; }
    seedbox_save() { APPLIED=1; }
}

# nothing applied, and the domain is still the old one
domain_untouched() {
    [[ $APPLIED == 0 && $SEEDBOX_DOMAIN == old.example.org && $SEEDBOX_LETSENCRYPT == auto ]] || {
        echo "applied: $APPLIED, domain: $SEEDBOX_DOMAIN, letsencrypt: $SEEDBOX_LETSENCRYPT"
        return 1
    }
}

domain_change_empty_answer_goes_back() (
    domain_menu_load
    answers ""
    if seedbox_change_domain >"$WORK/domain.out" 2>&1; then return 1; fi
    domain_untouched
)

domain_change_same_name_keeps_certificate() (
    domain_menu_load
    answers "old.example.org"
    seedbox_change_domain >"$WORK/domain.out" 2>&1
    domain_untouched && grep -q 'Nothing to change' "$WORK/domain.out"
)

domain_change_warns_before_replacing_certificate() (
    domain_menu_load
    answers "new.example.org"
    seedbox_change_domain >"$WORK/domain.out" 2>&1
    domain_untouched && grep -q 'will be deleted' "$WORK/domain.out"
)

domain_change_back_when_name_points_elsewhere() (
    domain_menu_load
    answers "elsewhere.test" "b"
    if seedbox_change_domain >"$WORK/domain.out" 2>&1; then return 1; fi
    domain_untouched || return 1
    # Q, the key of 1.2.x, still goes back
    answers "elsewhere.test" "q"
    if seedbox_change_domain >"$WORK/domain.out" 2>&1; then return 1; fi
    domain_untouched
)

domain_change_applied_once_confirmed() (
    domain_menu_load
    confirm() { return 0; }
    answers "new.example.org"
    seedbox_change_domain >"$WORK/domain.out" 2>&1
    [[ $APPLIED == 1 && $SEEDBOX_DOMAIN == new.example.org ]]
)

# --- firewall: refusing new rules puts the previous ones back --------------------
# The answer to « Does it work? » comes from standard input; the nft and
# systemd-run commands are recorded in $WORK/fw/calls.

firewall_trial_load() {
    load
    INTERACTIVE=1
    rm -rf "$WORK/fw"
    mkdir -p "$WORK/fw"
    : >"$WORK/fw/calls"
    FIREWALL_RULES="$WORK/fw/firewall.nft"
    FIREWALL_CANDIDATE="$WORK/fw/firewall.nft.new"
    FIREWALL_CONF_FILE="$WORK/fw/firewall.conf"
    FIREWALL_UNIT="$WORK/fw/seedtunnel-firewall.service"
    apt_install() { :; }
    firewall_generate_rules() { echo "new rules"; }
    firewall_summary() { echo SSH; }
    confirm() { return 0; }
    pause() { :; }
    clear() { :; }
    chown() { :; }
    # everything works; the automatic undo, once stopped, is no longer active
    systemctl() { [[ $1 != is-active ]]; }
    nft() { echo "nft $*" >>"$WORK/fw/calls"; }
    systemd-run() { echo "systemd-run $*" >>"$WORK/fw/calls"; }
    # a new SSH login went through the new rules
    journalctl() { echo "Accepted publickey for admin from 203.0.113.5 port 50000 ssh2: ED25519 SHA256:x"; }
    # this session comes from the Internet
    SSH_CONNECTION="203.0.113.5 49999 198.51.100.1 22"
    who() { :; }
    # addresses of the server
    ip() {
        printf '%s\n' '1: lo    inet 127.0.0.1/8 scope host lo' \
            '2: eth0    inet 198.51.100.1/24 brd 198.51.100.255 scope global eth0' \
            '2: eth0    inet6 2001:db8::1/64 scope global' '3: wg0    inet 10.8.0.1/24 scope global wg0'
    }
}

firewall_was_on() {
    echo "old rules" >"$FIREWALL_RULES"
    FIREWALL_ENABLED=1
    state_write "$FIREWALL_CONF_FILE" FIREWALL_ENABLED
}

firewall_change_refused_restores_previous_rules() (
    firewall_trial_load
    firewall_was_on
    firewall_enable <<<"no" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/calls"
    [[ $(<"$FIREWALL_RULES") == "old rules" && ! -e $FIREWALL_CANDIDATE ]] || return 1
    # undo, now and in 2 minutes: the old rules again, never « no firewall »
    grep -qx "nft -f $FIREWALL_RULES" "$WORK/fw/calls" \
        && grep -q "systemd-run .* /usr/sbin/nft -f $FIREWALL_RULES" "$WORK/fw/calls" \
        && ! grep -q "delete table" "$WORK/fw/calls"
)

firewall_first_trial_refused_leaves_nothing() (
    firewall_trial_load
    firewall_enable <<<"no" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/calls"
    [[ ! -e $FIREWALL_RULES && ! -e $FIREWALL_CANDIDATE ]] && ! firewall_enabled \
        && grep -qx "nft delete table inet $FIREWALL_TABLE" "$WORK/fw/calls"
)

firewall_change_confirmed_becomes_permanent() (
    firewall_trial_load
    firewall_was_on
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    [[ $(<"$FIREWALL_RULES") == "new rules" && ! -e $FIREWALL_CANDIDATE ]] && firewall_enabled
)

# --- firewall (1.2.5): every change of state checked ------------------------------

firewall_disable_checked() (
    firewall_trial_load
    firewall_was_on
    # the table cannot be deleted: it is still there
    nft() {
        echo "nft $*" >>"$WORK/fw/calls"
        [[ $1 != delete ]]
    }
    if (firewall_disable) &>"$WORK/fw/out"; then return 1; fi
    cat "$WORK/fw/out"
    # still on: nothing deleted, and said
    [[ -e $FIREWALL_RULES && -e $FIREWALL_CONF_FILE ]] && grep -q "could not be removed" "$WORK/fw/out"
)

firewall_rollback_cancel_checked() (
    firewall_trial_load
    firewall_was_on
    # the automatic undo cannot be stopped
    systemctl() { [[ $1 == is-active ]]; }
    if (firewall_enable <<<"yes") &>"$WORK/fw/out"; then return 1; fi
    cat "$WORK/fw/out"
    # the previous rules are back and stay the ones loaded at boot
    [[ $(<"$FIREWALL_RULES") == "old rules" && ! -e $FIREWALL_CANDIDATE ]] \
        && grep -qx "nft -f $FIREWALL_RULES" "$WORK/fw/calls"
)

firewall_refresh_keeps_boot_file() (
    firewall_trial_load
    firewall_was_on
    # nftables refuses the new rules
    nft() {
        echo "nft $*" >>"$WORK/fw/calls"
        return 1
    }
    if (firewall_refresh) &>"$WORK/fw/out"; then return 1; fi
    [[ $(<"$FIREWALL_RULES") == "old rules" ]]
)

firewall_boot_service_put_right() (
    firewall_trial_load
    # enabling the service loaded at boot fails
    systemctl() { [[ $1 != enable && $1 != is-active ]]; }
    if (firewall_enable <<<"yes") &>"$WORK/fw/out"; then return 1; fi
    # on in the settings, so the next run puts it right
    firewall_enabled || return 1
    systemctl() {
        echo "systemctl $*" >>"$WORK/fw/calls"
        [[ $1 != is-enabled ]]
    }
    firewall_refresh &>"$WORK/fw/out" || return 1
    grep -qx "systemctl enable --now seedtunnel-firewall.service" "$WORK/fw/calls"
)

vpn_uninstall_checked() (
    load
    VPN_STATE_DIR="$WORK/vpn-uninstall"
    VPN_CONF_FILE="$WORK/vpn-uninstall.conf"
    mkdir -p "$VPN_STATE_DIR/clients"
    echo key >"$VPN_STATE_DIR/server.key"
    echo "VPN_PORT=51820" >"$VPN_CONF_FILE"
    confirm() { return 0; }
    clear() { :; }
    pause() { :; }
    systemctl() { :; }
    nft() { :; }
    # wg0 is still there after the stop
    ip() { [[ $1 == link ]]; }
    if (vpn_uninstall) &>"$WORK/vpn-uninstall.out"; then return 1; fi
    cat "$WORK/vpn-uninstall.out"
    [[ -s $VPN_STATE_DIR/server.key && -e $VPN_CONF_FILE ]] && grep -q "could not be stopped" "$WORK/vpn-uninstall.out"
)

# --- VPN: a change that failed is applied at the next run ------------------------

vpn_change_failed_then_retried() (
    load
    VPN_PORT=51820
    : >"$WORK/syncconf"
    systemctl() { return 0; }
    wg-quick() { printf '[Interface]\n'; }
    nft() { return 0; }
    wg() {
        case $1 in
            show) echo 51820 ;;
            syncconf)
                echo call >>"$WORK/syncconf"
                # the first application fails, the next ones work
                (($(wc -l <"$WORK/syncconf") > 1))
                ;;
        esac
    }
    # first run: the files changed, WireGuard refuses them → failure reported
    if (vpn_reconcile 1) </dev/null &>/dev/null; then return 1; fi
    # next run: the files are already written (nothing changed), yet the
    # running VPN is put in line with them
    vpn_reconcile 0 </dev/null &>/dev/null || return 1
    (($(wc -l <"$WORK/syncconf") == 2))
)

# --- backups: a failed backup never becomes « the latest backup » ----------------

backup_load() {
    load
    BACKUP_DIR="$WORK/backups"
    rm -rf "$BACKUP_DIR"
    BACKUP_PASSPHRASE="a test passphrase"
    backup_paths() { echo etc/hostname; }
}

backup_failed_leaves_nothing() (
    backup_load
    # tar stops halfway (disk error, file gone…)
    tar() {
        if [[ $1 == -czf ]]; then
            printf 'half an archive'
            return 2
        fi
        command tar "$@"
    }
    if (backup_write "$BACKUP_DIR/test.tar.gz.enc") </dev/null &>/dev/null; then return 1; fi
    ls -A "$BACKUP_DIR"
    [[ -z $(ls -A "$BACKUP_DIR") && -z $(backup_latest) ]]
)

backup_complete_and_checked() (
    backup_load
    backup_write "$BACKUP_DIR/test.tar.gz.enc" </dev/null &>/dev/null || return 1
    [[ -s $BACKUP_DIR/test.tar.gz.enc && ! -e $BACKUP_DIR/test.tar.gz.enc.partial ]] || return 1
    [[ $(backup_latest) == "$BACKUP_DIR/test.tar.gz.enc" ]] || return 1
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass pass:"a test passphrase" \
        -in "$BACKUP_DIR/test.tar.gz.enc" | tar -tzf - | grep -qx etc/hostname
)

# --- firewall: a failed undo is never announced as done --------------------------

firewall_undo_failure_keeps_automatic_undo() (
    firewall_trial_load
    firewall_was_on
    systemctl() { echo "systemctl $*" >>"$WORK/fw/calls"; }
    nft() {
        echo "nft $*" >>"$WORK/fw/calls"
        # putting the previous rules back fails
        [[ "$*" != "-f $FIREWALL_RULES" ]]
    }
    if (firewall_enable <<<"no") >"$WORK/fw/out" 2>&1; then return 1; fi
    cat "$WORK/fw/calls"
    # once the automatic undo is scheduled, its timer is never stopped
    ! sed -n '/^systemd-run/,$p' "$WORK/fw/calls" | grep -q "systemctl stop"
)

# --- a configuration refused once is applied at the next run ----------------------
# The first application fails, the next ones work: the second run must apply
# again, although the file did not change since the first one.

retried() { echo call >>"$1" && (($(wc -l <"$1") > 1)); }
calls() { wc -l <"$1"; }

firewall_refresh_retried_after_failure() (
    load
    rm -rf "$APP_STATE_DIR/pending"
    : >"$WORK/nft-calls"
    FIREWALL_RULES="$WORK/pending.nft"
    FIREWALL_UNIT="$WORK/pending.service"
    rm -f "$FIREWALL_RULES"
    firewall_enabled() { return 0; }
    firewall_generate_rules() { echo "new rules"; }
    chown() { :; }
    systemctl() { :; }
    nft() { retried "$WORK/nft-calls"; }
    if (firewall_refresh) &>/dev/null; then return 1; fi
    firewall_refresh &>/dev/null || return 1
    (($(calls "$WORK/nft-calls") == 2))
)

nginx_reload_retried_after_failure() (
    load
    rm -rf "$APP_STATE_DIR/pending"
    : >"$WORK/nginx-reloads"
    NGINX_SITE="$WORK/nginx-site"
    NGINX_SITE_LINK="$WORK/nginx-link"
    NGINX_DEFAULT_SITE="$WORK/nginx-default"
    rm -f "$NGINX_SITE"
    ln -sfn "$NGINX_SITE" "$NGINX_SITE_LINK"
    nginx_generate_site() { echo "server {}"; }
    chown() { :; }
    nginx() { return 0; }
    systemctl() {
        case $1 in
            reload-or-restart) retried "$WORK/nginx-reloads" ;;
            *) return 0 ;;
        esac
    }
    if (seedbox_apply_nginx) &>/dev/null; then return 1; fi
    seedbox_apply_nginx &>/dev/null || return 1
    (($(calls "$WORK/nginx-reloads") == 2))
)

# What « sshd -T » shows for the seedbox account when its SFTP rule applies
sshd_rule_in_force() {
    printf 'chrootdirectory %s\nforcecommand internal-sftp -u 0002\n' "$SEEDBOX_DATA_DIR"
    printf '%s no\n' permittty allowtcpforwarding allowagentforwarding allowstreamlocalforwarding x11forwarding \
        permittunnel kbdinteractiveauthentication
    printf 'passwordauthentication %s\npubkeyauthentication yes\nauthorizedkeysfile %s/%%u\n' \
        "$SEEDBOX_SFTP_PASSWORD" "$SFTP_KEYS_DIR"
}

ssh_reload_retried_after_failure() (
    load
    rm -rf "$APP_STATE_DIR/pending"
    : >"$WORK/ssh-reloads"
    SSHD_SEEDBOX_CONF="$WORK/sshd-seedbox.conf"
    SFTP_KEYS_DIR="$WORK/sftp-keys"
    rm -f "$SSHD_SEEDBOX_CONF"
    SEEDBOX_USER=lancelot
    SEEDBOX_DATA_DIR="$WORK/data"
    SEEDBOX_SFTP_PASSWORD=yes
    sshd_generate_seedbox_conf() { echo "Match User lancelot"; }
    chown() { :; }
    sshd() { if [[ $1 == -T ]]; then sshd_rule_in_force; fi; }
    systemctl() { retried "$WORK/ssh-reloads"; }
    if (seedbox_apply_sftp) &>"$WORK/ssh.out"; then
        cat "$WORK/ssh.out"
        return 1
    fi
    seedbox_apply_sftp &>>"$WORK/ssh.out" || {
        cat "$WORK/ssh.out"
        return 1
    }
    (($(calls "$WORK/ssh-reloads") == 2))
)

# --- seedbox removal: the account goes before its SFTP restrictions ---------------

uninstall_stops_when_user_remains() (
    load
    OPT_YES=1
    local root="$WORK/uninstall" var
    rm -rf "$root"
    mkdir -p "$root"
    SEEDBOX_USER=lancelot
    SEEDBOX_DATA_DIR="$root/data"
    for var in SSHD_SEEDBOX_CONF NGINX_SITE NGINX_SITE_LINK NGINX_HTPASSWD FAIL2BAN_JAIL FAIL2BAN_MAIN_CONF \
        TRANSMISSION_DROPIN SFTP_KEYS_DIR SEEDBOX_SSL_DIR LETSENCRYPT_WEBROOT SHARE_DIR SEEDBOX_SECRETS_FILE; do
        printf -v "$var" '%s' "$root/$var"
    done
    echo "Match User lancelot" >"$SSHD_SEEDBOX_CONF"
    echo "SEEDBOX_USER=lancelot" >"$SEEDBOX_CONF_FILE"
    # the account exists and cannot be deleted (« user is currently used by process »)
    id() { [[ $1 == lancelot ]]; }
    userdel() { return 8; }
    pkill() { :; }
    sleep() { :; }
    systemctl() { :; }
    certbot() { :; }
    apt_purge() { :; }
    diskguard_remove() { :; }
    net_hardening_cleanup() { :; }
    firewall_refresh() { :; }
    backup_auto_stop_if_unused() { :; }
    if (seedbox_uninstall) &>"$WORK/uninstall.out"; then return 1; fi
    cat "$WORK/uninstall.out"
    # the SFTP restrictions and the state are still there
    [[ -e $SSHD_SEEDBOX_CONF && -e $SEEDBOX_CONF_FILE ]]
)

# --- backups: never written through a link prepared in advance -------------------

backup_does_not_follow_prepared_link() (
    backup_load
    install -d -m 700 "$BACKUP_DIR"
    echo "precious" >"$WORK/victim"
    # links at the names a backup could use
    ln -s "$WORK/victim" "$BACKUP_DIR/test.tar.gz.enc.partial"
    backup_write "$BACKUP_DIR/test.tar.gz.enc" </dev/null &>/dev/null || return 1
    [[ $(<"$WORK/victim") == precious && -f $BACKUP_DIR/test.tar.gz.enc && ! -L $BACKUP_DIR/test.tar.gz.enc ]]
)

backup_refuses_open_folder() (
    backup_load
    mkdir -p "$WORK/shared"
    chmod 777 "$WORK/shared"
    if (backup_write "$WORK/shared/test.tar.gz.enc") </dev/null &>"$WORK/open.out"; then return 1; fi
    cat "$WORK/open.out"
    [[ -z $(ls -A "$WORK/shared") ]]
)

# --- one-time links: no link without its watcher ---------------------------------

share_load() {
    load
    SHARE_DIR="$WORK/share-$1"
    rm -rf "$SHARE_DIR"
    SEEDBOX_DOMAIN=seedbox.example.org
    SEEDBOX_CERTIFICATE=letsencrypt
    echo secret >"$WORK/to-share"
    apt_install() { :; }
    seedbox_apply_nginx() { :; }
    # install without -o / -g (the tests do not run as root)
    install() { share_install "$@"; }
    share_install() {
        local -a args=()
        while (($#)); do
            case $1 in
                -o | -g) shift 2 ;;
                *)
                    args+=("$1")
                    shift
                    ;;
            esac
        done
        command install "${args[@]}"
    }
    chown() { :; }
    systemd-run() { :; }
    systemctl() { echo "systemctl $*" >>"$WORK/share-calls"; }
    sleep() { :; }
}

share_prepared_halfway_deleted() (
    share_load halfway
    pgrep() { return 0; }
    # the disk is full: the file of the link cannot be copied
    install() {
        if [[ " $* " == *" $WORK/to-share "* ]]; then return 1; fi
        share_install "$@"
    }
    if (share_create "$WORK/to-share" file.conf Title "" Note) &>"$WORK/share.out"; then
        cat "$WORK/share.out"
        return 1
    fi
    # no folder of a link left behind, and no link shown
    [[ -z $(find "$SHARE_DIR" -mindepth 1 -maxdepth 1 2>/dev/null) ]] && ! grep -q "https://" "$WORK/share.out"
)

share_refused_without_watcher() (
    share_load nowatch
    # the watcher never shows up
    pgrep() { return 1; }
    if (share_create "$WORK/to-share" file.conf Title "" Note) &>"$WORK/share.out"; then
        cat "$WORK/share.out"
        return 1
    fi
    # no link shown, nothing left to download
    ! grep -q "https://" "$WORK/share.out" && [[ -z $(ls -A "$SHARE_DIR") ]]
)

# --- diagnostics: a weekly backup that never worked is reported -------------------

doctor_reports_first_backup_missing() (
    load
    BACKUP_DIR="$WORK/doctor-backups"
    mkdir -p "$BACKUP_DIR"
    BACKUP_PASSPHRASE_FILE="$WORK/doctor-passphrase"
    BACKUP_DOWNLOADED_MARK="$WORK/doctor-mark"
    # turned on 10 days ago, and no automatic backup since
    touch -d '10 days ago' "$BACKUP_PASSPHRASE_FILE"
    touch "$BACKUP_DOWNLOADED_MARK"
    backup_auto_enabled() { return 0; }
    systemctl() { return 1; }
    DOCTOR_ERRORS=0
    DOCTOR_WARNINGS=0
    doctor_backup >"$WORK/doctor.out" 2>&1
    cat "$WORK/doctor.out"
    ((DOCTOR_WARNINGS == 1)) && grep -q "since it was turned on 10 days ago" "$WORK/doctor.out"
)

# --- restore: no decrypted secrets left after a failure ---------------------------

restore_cleans_up_after_failure() (
    load
    local root="$WORK/restore-root"
    rm -rf "$root" "$WORK/restore-tmp"
    mkdir -p "$root/etc/seedtunnel" "$WORK/restore-tmp"
    echo "VPN_PORT=51820" >"$root/etc/seedtunnel/vpn.conf"
    tar -czf - -C "$root" etc/seedtunnel | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
        -pass pass:"a test passphrase" -out "$WORK/restore.enc"
    echo "a test passphrase" >"$WORK/restore-passphrase"
    chmod 600 "$WORK/restore-passphrase"
    OPT_PASSPHRASE_FILE="$WORK/restore-passphrase"
    OPT_YES=1
    export TMPDIR="$WORK/restore-tmp"
    # the extraction fails (disk full…)
    tar() {
        if [[ $1 == -xzf ]]; then return 2; fi
        command tar "$@"
    }
    if (restore_main "$WORK/restore.enc") &>"$WORK/restore.out"; then return 1; fi
    ls -AR "$WORK/restore-tmp"
    [[ -z $(ls -A "$WORK/restore-tmp") ]]
)

# --- full disk: Transmission does not start (at boot either) ----------------------

diskguard_refuses_start_on_full_disk() (
    load
    DISKGUARD_MARKER="$WORK/diskguard.stopped"
    rm -f "$DISKGUARD_MARKER"
    SEEDBOX_DATA_DIR=$WORK
    seedbox_installed() { return 0; }
    logger() { :; }
    disk_free_gb() { echo 1; }
    if diskguard_prestart &>/dev/null; then return 1; fi
    [[ -e $DISKGUARD_MARKER ]] || return 1
    # room again: it may start
    disk_free_gb() { echo 50; }
    diskguard_prestart &>/dev/null && [[ ! -e $DISKGUARD_MARKER ]]
)

# --- update: the installed version stays until the new one works ------------------

update_failed_keeps_previous_version() (
    load
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app"
    mkdir -p "$APP_DIR" "$WORK/app/new"
    printf '#!/bin/sh\necho old >>"%s"\n' "$WORK/app/applied" >"$APP_DIR/seedtunnel.sh"
    # the new version cannot apply the configuration
    printf '#!/bin/sh\nexit 7\n' >"$WORK/app/new/seedtunnel.sh"
    chmod +x "$APP_DIR/seedtunnel.sh" "$WORK/app/new/seedtunnel.sh"
    if (update_switch "$WORK/app/new" 9.9.9) &>"$WORK/update.out"; then
        cat "$WORK/update.out"
        return 1
    fi
    # the previous version is back, and it applied its configuration again
    grep -q "echo old" "$APP_DIR/seedtunnel.sh" && [[ $(<"$WORK/app/applied") == old ]]
)

# installed version (records « old » when it applies) and new version (records
# « new », then ends with status $1)
update_versions_make() {
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app"
    mkdir -p "$APP_DIR" "$WORK/app/new"
    printf '#!/bin/sh\necho old >>"%s"\n' "$WORK/app/applied" >"$APP_DIR/seedtunnel.sh"
    printf '#!/bin/sh\necho new >>"%s"\nexit %s\n' "$WORK/app/applied" "$1" >"$WORK/app/new/seedtunnel.sh"
    chmod +x "$APP_DIR/seedtunnel.sh" "$WORK/app/new/seedtunnel.sh"
}

update_refused_when_previous_left() (
    load
    update_versions_make 0
    # left by an update cut short: maybe the only working copy
    mkdir "$APP_DIR.previous"
    echo kept >"$APP_DIR.previous/marker"
    if (update_switch "$WORK/app/new" 9.9.9) &>"$WORK/update.out"; then return 1; fi
    grep -q "did not finish" "$WORK/update.out" || return 1
    [[ $(<"$APP_DIR.previous/marker") == kept ]] && grep -q "echo old" "$APP_DIR/seedtunnel.sh" \
        && [[ ! -e $WORK/app/applied ]]
)

update_second_rename_failure_puts_back() (
    load
    update_versions_make 0
    # the new version cannot be moved in place
    mv() {
        if [[ $* == *"$WORK/app/new"* ]]; then return 1; fi
        command mv "$@"
    }
    if (update_switch "$WORK/app/new" 9.9.9) &>"$WORK/update.out"; then return 1; fi
    grep -q "version $APP_VERSION kept" "$WORK/update.out" || return 1
    # the installed version is back at once, nothing was applied
    grep -q "echo old" "$APP_DIR/seedtunnel.sh" && [[ ! -e $APP_DIR.previous && ! -e $WORK/app/applied ]]
)

update_old_apply_failure_reported() (
    load
    update_versions_make 7
    # the installed version fails too, when it applies its configuration again
    printf '#!/bin/sh\necho old >>"%s"\nexit 3\n' "$WORK/app/applied" >"$APP_DIR/seedtunnel.sh"
    if (update_switch "$WORK/app/new" 9.9.9) &>"$WORK/update.out"; then return 1; fi
    cat "$WORK/update.out"
    grep -q "files of version $APP_VERSION are back, but putting the configuration back into service failed" "$WORK/update.out" \
        && [[ $(tr '\n' ' ' <"$WORK/app/applied") == "new old " ]]
)

# git repository with the installed version (one commit) and the new one (tag
# v9.9.9, whose seedtunnel.sh ends with status 7). As in the real repository,
# lib/common.sh says the version of each.
update_git_make() {
    update_versions_make 7
    APP_VERSION=1.0.0
    confirm() { return 0; }
    mkdir -p "$APP_DIR/lib"
    echo 'APP_VERSION="1.0.0"' >"$APP_DIR/lib/common.sh"
    git -C "$APP_DIR" init --quiet
    git -C "$APP_DIR" add -A
    git -C "$APP_DIR" -c user.name=t -c user.email=t@t commit --quiet -m old
    cp "$WORK/app/new/seedtunnel.sh" "$APP_DIR/seedtunnel.sh"
    echo "APP_VERSION=\"${UPDATE_TAG_CODE_VERSION:-9.9.9}\"" >"$APP_DIR/lib/common.sh"
    git -C "$APP_DIR" -c user.name=t -c user.email=t@t commit --quiet -am new
    git -C "$APP_DIR" tag v9.9.9
    git -C "$APP_DIR" checkout --quiet HEAD~1
    UPDATE_OLD=$(git -C "$APP_DIR" rev-parse HEAD)
    # no network: the tags are already there
    fetch_stub() { [[ $* == *fetch* ]]; }
}

update_git_failed_goes_back() (
    load
    update_git_make
    git() {
        if fetch_stub "$@"; then return 0; fi
        command git "$@"
    }
    if (update_from_git) &>"$WORK/update.out"; then return 1; fi
    [[ $(command git -C "$APP_DIR" rev-parse HEAD) == "$UPDATE_OLD" ]] \
        && [[ $(tr '\n' ' ' <"$WORK/app/applied") == "new old " ]]
)

update_git_head_checked() (
    load
    update_git_make
    # going back to the previous commit « succeeds » but HEAD does not move
    git() {
        if fetch_stub "$@" || [[ $* == *"checkout --quiet $UPDATE_OLD"* ]]; then return 0; fi
        command git "$@"
    }
    if (update_from_git) &>"$WORK/update.out"; then return 1; fi
    cat "$WORK/update.out"
    # stopped with the git command, without applying the version that failed again
    grep -q "checkout $UPDATE_OLD" "$WORK/update.out" && [[ $(<"$WORK/app/applied") == new ]]
)

# --- validation of addresses and ports ----------------------------------------------

validators_reject_out_of_range() (
    load
    is_ipv4 192.168.1.1 && is_ipv4 0.0.0.0 && ! is_ipv4 256.1.2.3 && ! is_ipv4 999.999.999.999 || return 1
    is_valid_port 1 && is_valid_port 65535 && ! is_valid_port 0 && ! is_valid_port 65536 \
        && ! is_valid_port 080 && ! is_valid_port 010 || return 1
    vpn_is_valid_dns "1.1.1.1, 1.0.0.1" && vpn_is_valid_dns "2620:fe::fe" \
        && ! vpn_is_valid_dns "a" && ! vpn_is_valid_dns "," && ! vpn_is_valid_dns "300.1.1.1"
)

# --- SFTP: never an account without its restrictions ------------------------------

sftp_load() {
    load
    rm -rf "$APP_STATE_DIR/pending"
    SSHD_SEEDBOX_CONF="$WORK/sshd-seedbox.conf"
    SFTP_KEYS_DIR="$WORK/sftp-keys"
    rm -f "$SSHD_SEEDBOX_CONF"
    : >"$WORK/user-calls"
    SEEDBOX_USER=lancelot
    SEEDBOX_DATA_DIR="$WORK/data"
    SEEDBOX_SFTP_PASSWORD=yes
    sshd_generate_seedbox_conf() { echo "Match User lancelot"; }
    chown() { :; }
    systemctl() { :; }
    sleep() { :; }
    id() { [[ $1 == lancelot ]]; }
    # the expiry date of the account is kept in $WORK/expiry
    rm -f "$WORK/expiry"
    usermod() {
        echo "usermod $*" >>"$WORK/user-calls"
        if [[ $1 == --expiredate ]]; then printf '%s' "$2" >"$WORK/expiry"; fi
    }
    getent() {
        case $1 in
            shadow) printf '%s:!:20000:0:99999:7::%s:\n' "$2" "$(cat "$WORK/expiry" 2>/dev/null)" ;;
            group) [[ $2 == lancelot ]] ;;
            *) return 2 ;;
        esac
    }
    pkill() { echo "pkill $*" >>"$WORK/user-calls"; }
    pgrep() { return 1; }
}

sftp_rule_not_applied_suspends_account() (
    sftp_load
    # sshd accepts the file, but a Match block placed before ours wins: no
    # chroot, and tunnels allowed for the account
    sshd() { if [[ $1 == -T ]]; then printf 'chrootdirectory none\nforcecommand none\nallowtcpforwarding yes\n'; fi; }
    if (seedbox_apply_sftp) &>"$WORK/sftp.out"; then
        cat "$WORK/sftp.out"
        return 1
    fi
    cat "$WORK/user-calls"
    grep -qxF "usermod --expiredate 1 lancelot" "$WORK/user-calls" \
        && grep -qxF "pkill -KILL -u lancelot" "$WORK/user-calls" || return 1
    # once the rule applies, the account suspended by seedtunnel comes back
    sshd() { if [[ $1 == -T ]]; then sshd_rule_in_force; fi; }
    seedbox_apply_sftp &>>"$WORK/sftp.out" || return 1
    grep -qxF "usermod --expiredate  lancelot" "$WORK/user-calls"
)

rename_suspends_account_first() (
    sftp_load
    SFTP_KEYS_DIR="$WORK/rename-keys"
    groupmod() { :; }
    seedbox_save() { :; }
    seedbox_apply() { echo "apply" >>"$WORK/user-calls"; }
    seedbox_set_credentials galahad &>"$WORK/rename.out" || {
        cat "$WORK/rename.out"
        return 1
    }
    cat "$WORK/user-calls"
    # suspended, sessions closed, then renamed: never an account named
    # galahad that the rule written for lancelot does not cover
    [[ $(head -n 3 "$WORK/user-calls") == $'usermod --expiredate 1 lancelot\npkill -KILL -u lancelot\nusermod --login galahad lancelot' ]]
)

# --- self-signed certificate: its fingerprint comes with every link ----------------

share_shows_selfsigned_fingerprint() (
    share_load fingerprint
    SEEDBOX_CERTIFICATE=selfsigned
    SEEDBOX_DOMAIN=203.0.113.7
    SEEDBOX_SSL_DIR="$WORK/ssl"
    mkdir -p "$SEEDBOX_SSL_DIR"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=203.0.113.7 \
        -keyout "$SEEDBOX_SSL_DIR/selfsigned.key" -out "$SEEDBOX_SSL_DIR/selfsigned.crt" &>/dev/null || return 1
    pgrep() { return 0; }
    share_create "$WORK/to-share" file.conf Title "" Note &>"$WORK/share-fp.out" || {
        cat "$WORK/share-fp.out"
        return 1
    }
    cat "$WORK/share-fp.out"
    grep -qF "$(openssl x509 -in "$SEEDBOX_SSL_DIR/selfsigned.crt" -noout -fingerprint -sha256 | cut -d= -f2)" "$WORK/share-fp.out"
)

# --- files holding a secret: readable by their owner only ---------------------------

secret_files_must_be_private() (
    load
    printf 'VPN_PORT=51820\n' >"$WORK/open.conf"
    printf 'a test passphrase\n' >"$WORK/open-passphrase"
    chmod 644 "$WORK/open.conf"
    chmod 640 "$WORK/open-passphrase"
    OPT_PASSPHRASE_FILE="$WORK/open-passphrase"
    if (config_load "$WORK/open.conf") &>"$WORK/secret.out"; then return 1; fi
    if (backup_read_passphrase 0) &>>"$WORK/secret.out"; then return 1; fi
    cat "$WORK/secret.out"
    # readable by their owner only: accepted
    chmod 600 "$WORK/open.conf" "$WORK/open-passphrase"
    (config_load "$WORK/open.conf") && (backup_read_passphrase 0) </dev/null
)

# --- firewall: « yes » only counts once a new SSH login went through -------------

firewall_yes_needs_new_ssh_login() (
    firewall_trial_load
    firewall_was_on
    # « yes » typed, but no new SSH login since the rules were applied
    journalctl() { :; }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    [[ $(<"$FIREWALL_RULES") == "old rules" && ! -e $FIREWALL_CANDIDATE ]] || return 1
    # a login of the SFTP account (it may come through the VPN) does not count
    SEEDBOX_USER=lancelot
    journalctl() { echo "Accepted password for lancelot from 10.8.0.2 port 50000 ssh2"; }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    [[ $(<"$FIREWALL_RULES") == "old rules" ]]
)

# --- packages: a removal only takes what seedtunnel installed ----------------------

packages_load() {
    load
    # a new server: nothing installed by seedtunnel yet
    rm -f "$APP_STATE_DIR/packages" "$APP_STATE_DIR/vpn.conf" "$APP_STATE_DIR/seedbox.conf" "$WORK/apt-calls"
    printf '%s\n' curl nginx unrelated >"$WORK/installed"
    package_installed() { grep -qxF -- "$1" "$WORK/installed"; }
    packages_installed_list() { LC_ALL=C sort "$WORK/installed"; }
    APP_APT_UPDATED=1
}

# apt-get as the tests need it: the simulation of a purge (-s … purge) removes
# exactly the packages asked for, unless $WORK/also-removed adds some;
# « -s autoremove » prints $WORK/autoremove
apt_get_stub() {
    apt-get() {
        echo "apt-get $*" >>"$WORK/apt-calls"
        if [[ $1 == -s && $* == *" purge "* ]]; then
            local package
            for package in "${@:5}"; do echo "Purg $package [1.0]"; done
            if [[ -s $WORK/also-removed ]]; then sed 's/^/Purg /; s/$/ [2.0]/' "$WORK/also-removed"; fi
        elif [[ $1 == -s ]]; then
            cat "$WORK/autoremove" 2>/dev/null || true
        fi
    }
    rm -f "$WORK/also-removed" "$WORK/autoremove"
}

install_records_what_it_brought() (
    packages_load
    apt-get() {
        echo "apt-get $*" >>"$WORK/apt-calls"
        # transmission-daemon comes with transmission-common
        if [[ $* == *" install "* ]]; then printf '%s\n' transmission-daemon transmission-common >>"$WORK/installed"; fi
    }
    # nginx was there before
    apt_install curl nginx transmission-daemon &>/dev/null || return 1
    cat "$APP_STATE_DIR/packages"
    [[ $(<"$APP_STATE_DIR/packages") == $'transmission-common\ntransmission-daemon' ]]
)

purge_only_what_seedtunnel_installed() (
    packages_load
    printf '%s\n' certbot libdep >>"$WORK/installed"
    printf '%s\n' certbot libdep >"$APP_STATE_DIR/packages"
    apt_get_stub
    # what nothing needs any more: a dependency of certbot, and a package
    # that has nothing to do with seedtunnel
    printf 'Remv libdep [1.0]\nRemv unrelated [2.0]\n' >"$WORK/autoremove"
    apt_purge nginx certbot &>"$WORK/purge.out" || {
        cat "$WORK/purge.out"
        return 1
    }
    cat "$WORK/apt-calls"
    grep -q " purge -y certbot$" "$WORK/apt-calls" && grep -q " purge -y libdep$" "$WORK/apt-calls" \
        && ! grep -q "nginx\|unrelated\|autoremove -y" "$WORK/apt-calls"
)

packages_from_older_version_still_removed() (
    packages_load
    # set up by a version without the list: what it installed is still removed
    echo "SEEDBOX_USER=lancelot" >"$APP_STATE_DIR/seedbox.conf"
    apt_get_stub
    apt_purge nginx certbot &>/dev/null || return 1
    cat "$WORK/apt-calls"
    grep -q " purge -y nginx$" "$WORK/apt-calls"
)

purge_kept_when_it_would_take_others() (
    packages_load
    printf '%s\n' certbot libdep other-app >>"$WORK/installed"
    printf '%s\n' nginx certbot libdep >"$APP_STATE_DIR/packages"
    apt_get_stub
    # a program installed later depends on nginx: APT would remove it too
    echo other-app >"$WORK/also-removed"
    apt_purge nginx &>"$WORK/purge.out" || return 1
    cat "$WORK/purge.out" "$WORK/apt-calls"
    ! grep -q " purge -y" "$WORK/apt-calls" && grep -q "other-app" "$WORK/purge.out" || return 1
    # the dependencies no longer needed are checked the same way
    : >"$WORK/apt-calls"
    rm -f "$WORK/also-removed"
    printf 'Remv libdep [1.0]\n' >"$WORK/autoremove"
    apt-get() {
        echo "apt-get $*" >>"$WORK/apt-calls"
        if [[ $1 == -s && $* == *" purge certbot"* ]]; then echo "Purg certbot [1.0]"; fi
        if [[ $1 == -s && $* == *" purge libdep"* ]]; then printf 'Purg libdep [1.0]\nPurg other-app [2.0]\n'; fi
        if [[ $1 == -s && $* == *autoremove* ]]; then cat "$WORK/autoremove"; fi
    }
    apt_purge certbot &>"$WORK/purge.out" || return 1
    cat "$WORK/apt-calls"
    grep -q " purge -y certbot$" "$WORK/apt-calls" && ! grep -q " purge -y libdep$" "$WORK/apt-calls"
)

registry_kept_when_list_unreadable() (
    packages_load
    printf '%s\n' certbot >>"$WORK/installed"
    printf '%s\n' certbot libdep >"$APP_STATE_DIR/packages"
    apt_get_stub
    # dpkg-query fails after the removal
    packages_installed_list() { return 1; }
    apt_purge certbot &>/dev/null || return 1
    [[ $(<"$APP_STATE_DIR/packages") == $'certbot\nlibdep' ]] || return 1
    # at the installation, a list that cannot be read: only the packages asked for
    rm -f "$APP_STATE_DIR/packages"
    apt_get_stub
    apt_install transmission-daemon &>/dev/null || return 1
    cat "$APP_STATE_DIR/packages"
    [[ $(<"$APP_STATE_DIR/packages") == transmission-daemon ]]
)

# --- Transmission: settings never half-written, Transmission not left stopped -----

transmission_settings_failure_keeps_them() (
    load
    TRANSMISSION_DROPIN="$WORK/dropin/seedtunnel.conf"
    SEEDBOX_DATA_DIR="$WORK/data"
    printf '{"old": true}\n' >"$WORK/settings.json"
    : >"$WORK/tr-calls"
    transmission_settings_file() { echo "$WORK/settings.json"; }
    transmission_desired_settings() { echo '{"new": true}'; }
    transmission_settings_uptodate() { return 1; }
    diskguard_stopped() { return 1; }
    chown() { :; }
    systemctl() { echo "systemctl $*" >>"$WORK/tr-calls"; }
    # the disk is full: the new settings stop halfway
    jq() {
        [[ $1 == empty ]] && return 1
        printf '{"old": true, "ne'
        return 1
    }
    if (seedbox_apply_transmission) &>"$WORK/tr.out"; then return 1; fi
    cat "$WORK/tr.out" "$WORK/tr-calls"
    # the previous settings are whole, nothing left behind, and Transmission runs again
    [[ $(<"$WORK/settings.json") == '{"old": true}' && ! -e $WORK/settings.json.tmp ]] \
        && grep -qx "systemctl start transmission-daemon" "$WORK/tr-calls" || return 1
    # it works: replaced in one go
    unset -f jq
    seedbox_apply_transmission &>"$WORK/tr.out" || return 1
    [[ $(jq -c . "$WORK/settings.json") == '{"old":true,"new":true}' && ! -e $WORK/settings.json.tmp ]]
)

transmission_waits_for_data_disk() (
    load
    SEEDBOX_DATA_DIR=/srv/seedbox
    transmission_generate_dropin | grep -qxF "RequiresMountsFor=/srv/seedbox"
)

# --- ports 80/443: every program listening is checked -----------------------------

web_ports_other_program_beside_nginx() (
    load
    # nginx on 80 (an earlier attempt), apache2 on 443
    ss() { printf '%s\n' 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=10,fd=6))' \
        'LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("apache2",pid=20,fd=4))'; }
    if (seedbox_check_web_ports) &>"$WORK/ports.out"; then return 1; fi
    grep -q apache2 "$WORK/ports.out" || return 1
    # nginx alone (the seedbox itself): fine
    ss() { echo 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=10,fd=6))'; }
    seedbox_check_web_ports
)

# --- full disk protection: a disk that cannot be measured is reported -------------

diskguard_warns_when_unmeasurable() (
    load
    DISKGUARD_MARKER="$WORK/diskguard.stopped"
    rm -f "$DISKGUARD_MARKER" "$WORK/logger"
    SEEDBOX_DATA_DIR="$WORK/missing-disk"
    seedbox_installed() { return 0; }
    logger() { echo "logger $*" >>"$WORK/logger"; }
    disk_free_gb() { :; }
    # Transmission is not stopped for it, but it is said, in the journal too
    diskguard_check &>"$WORK/dg.out" || return 1
    diskguard_prestart &>>"$WORK/dg.out" || return 1
    cat "$WORK/dg.out"
    grep -q "Cannot measure the free space" "$WORK/dg.out" && grep -q "cannot be measured" "$WORK/logger"
)

# --- diagnostics: the certificate served is checked as a browser does -------------

doctor_reports_certificate_refused() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seedbox.example.org
    DOCTOR_ERRORS=0
    DOCTOR_WARNINGS=0
    # valid on the disk, but the one served does not verify (curl: 60)
    curl() {
        [[ " $* " == *" -k "* || " $* " == *" -sk "* ]] && return 0
        return 60
    }
    doctor_certificate_served 203.0.113.7 &>"$WORK/cert.out"
    cat "$WORK/cert.out"
    ((DOCTOR_ERRORS == 1)) || return 1
    # served and trusted: fine
    curl() { return 0; }
    DOCTOR_ERRORS=0
    doctor_certificate_served 203.0.113.7 &>/dev/null
    ((DOCTOR_ERRORS == 0))
)

# --- VPN clients: what happens when the tunnel drops is explained ---------------

vpn_help_explains_kill_switch() (
    load
    i18n_load fr
    local name=laptop port=60002 VPN_PUBLIC_ADDRESS=203.0.113.7
    text_en_vpn_client_help | grep -q "kill switch" && text_fr_vpn_client_help | grep -q "kill switch" \
        && text_en_share_steps_vpn | grep -q "kill switch" && text_fr_share_steps_vpn | grep -q "kill switch"
)

# --- SFTP (1.2.2): suspension checked, rule checked from everywhere, rename undone -

sftp_suspension_failure_is_said() (
    sftp_load
    sshd() { if [[ $1 == -T ]]; then printf 'chrootdirectory none\n'; fi; }
    # the account database is locked: the expiry date cannot be written
    usermod() {
        echo "usermod $*" >>"$WORK/user-calls"
        return 1
    }
    if (seedbox_apply_sftp) &>"$WORK/sftp.out"; then return 1; fi
    cat "$WORK/sftp.out"
    grep -q "could not be suspended" "$WORK/sftp.out" || return 1
    # nor is an account renamed if it cannot be suspended first
    seedbox_apply() { :; }
    seedbox_save() { :; }
    if (seedbox_set_credentials galahad) &>"$WORK/rename.out"; then return 1; fi
    ! grep -q -- "--login" "$WORK/user-calls"
)

sftp_rule_checked_from_everywhere() (
    sftp_load
    # in force from the server itself only (a Match Address block for the
    # other addresses, placed before ours)
    sshd() {
        [[ $1 == -T ]] || return 0
        if [[ $3 == *addr=127.0.0.1* ]]; then sshd_rule_in_force; else printf 'chrootdirectory none\n'; fi
    }
    if (seedbox_apply_sftp) &>"$WORK/sftp.out"; then
        cat "$WORK/sftp.out"
        return 1
    fi
    # everywhere, but tunnels (PermitTunnel) still allowed
    sshd() { if [[ $1 == -T ]]; then sshd_rule_in_force | sed 's/^permittunnel no$/permittunnel yes/'; fi; }
    if (seedbox_apply_sftp) &>"$WORK/sftp.out"; then
        cat "$WORK/sftp.out"
        return 1
    fi
    grep -qxF "usermod --expiredate 1 lancelot" "$WORK/user-calls"
)

rename_undone_when_a_step_fails() (
    sftp_load
    SFTP_KEYS_DIR="$WORK/rename-keys"
    # the group cannot be renamed
    groupmod() {
        echo "groupmod $*" >>"$WORK/user-calls"
        return 1
    }
    seedbox_save() { echo "save" >>"$WORK/user-calls"; }
    seedbox_apply() { echo "apply" >>"$WORK/user-calls"; }
    if (seedbox_set_credentials galahad) &>"$WORK/rename.out"; then return 1; fi
    cat "$WORK/rename.out" "$WORK/user-calls"
    # the old name is back, the account is no longer suspended, nothing saved
    grep -qxF "usermod --login lancelot galahad" "$WORK/user-calls" \
        && [[ $(tail -n 1 "$WORK/user-calls") == "usermod --expiredate  lancelot" ]] \
        && ! grep -qx "save\|apply" "$WORK/user-calls"
)

# --- firewall: logins through the VPN or from the server itself do not count -----

firewall_vpn_login_does_not_count() (
    firewall_trial_load
    firewall_was_on
    # this session comes from the Internet: a login through the VPN proves
    # nothing for that way
    journalctl() {
        echo "Accepted publickey for admin from 10.8.0.2 port 50000 ssh2: ED25519 SHA256:x"
        echo "Accepted publickey for admin from 127.0.0.1 port 50001 ssh2: ED25519 SHA256:x"
    }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    [[ $(<"$FIREWALL_RULES") == "old rules" && ! -e $FIREWALL_CANDIDATE ]]
)

firewall_vpn_session_confirms_through_vpn() (
    firewall_trial_load
    firewall_was_on
    # this session comes through the VPN (after sudo: found from the terminal)
    unset SSH_CONNECTION
    who() { echo "admin    pts/0        2026-11-01 03:00 (10.8.0.2)"; }
    journalctl() { echo "Accepted publickey for admin from 10.8.0.2 port 50000 ssh2: ED25519 SHA256:x"; }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    [[ $(<"$FIREWALL_RULES") == "new rules" ]] || return 1
    # a login from the server itself never counts
    firewall_was_on
    journalctl() { echo "Accepted publickey for admin from 127.0.0.1 port 50000 ssh2: ED25519 SHA256:x"; }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    [[ $(<"$FIREWALL_RULES") == "old rules" ]]
)

firewall_internet_login_confirms_vpn_session() (
    firewall_trial_load
    firewall_was_on
    # this session comes through the VPN, the new login from the Internet:
    # the way the rules can break works
    SSH_CONNECTION="10.8.0.2 49999 10.8.0.1 22"
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    [[ $(<"$FIREWALL_RULES") == "new rules" ]]
)

firewall_login_from_server_itself_does_not_count() (
    firewall_trial_load
    firewall_was_on
    # « ssh admin@its-own-public-address » run on the server: never leaves it
    journalctl() {
        echo "Accepted publickey for admin from 198.51.100.1 port 50000 ssh2: ED25519 SHA256:x"
        echo "Accepted publickey for admin from 2001:db8::1 port 50001 ssh2: ED25519 SHA256:x"
    }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    [[ $(<"$FIREWALL_RULES") == "old rules" ]]
)

firewall_only_reads_messages_of_sshd() (
    firewall_trial_load
    firewall_was_on
    # the journal holds a login message, but not from an OpenSSH program: it
    # only comes out when the journal is read without the filter on _EXE
    journalctl() {
        [[ " $* " == *" _EXE="* ]] && return 0
        echo "Accepted publickey for admin from 203.0.113.5 port 50000 ssh2: ED25519 SHA256:x"
    }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    [[ $(<"$FIREWALL_RULES") == "old rules" ]]
)

# --- diagnostics: certificate not checked → said --------------------------------

doctor_says_certificate_not_checked() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seedbox.example.org
    DOCTOR_ERRORS=0
    DOCTOR_WARNINGS=0
    # connection refused
    curl() { return 7; }
    doctor_certificate_served 203.0.113.7 &>"$WORK/cert.out"
    cat "$WORK/cert.out"
    ((DOCTOR_WARNINGS == 1 && DOCTOR_ERRORS == 0))
)

# --- IPv6 addresses (DNS of the VPN) ---------------------------------------------

ipv6_forms() (
    load
    local good bad
    for good in 2620:fe::fe 2001:db8::1 ::1 :: fe80:: 2001:db8:0:0:0:0:0:1 1:2:3:4:5:6:7::; do
        vpn_is_valid_dns "$good" || {
            echo "refused: $good"
            return 1
        }
    done
    for bad in 2001:::1 1:2 2001:db8::1::2 12345::1 1:2:3:4:5:6:7:8:9 1::2:3:4:5:6:7:8 :1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:8: g::1; do
        if vpn_is_valid_dns "$bad"; then
            echo "accepted: $bad"
            return 1
        fi
    done
)

# --- restore stopped halfway: how to go back is said -------------------------------

restore_unfinished_says_how_to_go_back() (
    load
    local root="$WORK/restore2-root"
    rm -rf "$root" "$WORK/restore2-state"*
    mkdir -p "$root/etc/seedtunnel"
    echo "VPN_PORT=51820" >"$root/etc/seedtunnel/vpn.conf"
    tar -czf - -C "$root" etc/seedtunnel | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
        -pass pass:"a test passphrase" -out "$WORK/restore2.enc"
    echo "a test passphrase" >"$WORK/restore2-passphrase"
    chmod 600 "$WORK/restore2-passphrase"
    OPT_PASSPHRASE_FILE="$WORK/restore2-passphrase"
    OPT_YES=1
    # settings in place before the restore
    APP_STATE_DIR="$WORK/restore2-state"
    mkdir -p "$APP_STATE_DIR"
    echo "VPN_PORT=1194" >"$APP_STATE_DIR/vpn.conf"
    # the restore stops once the new settings are copied (disk full…)
    i18n_init() { die 'Disk full'; }
    if (restore_main "$WORK/restore2.enc") &>"$WORK/restore2.out"; then return 1; fi
    cat "$WORK/restore2.out"
    grep -q "did not finish" "$WORK/restore2.out" \
        && grep -q "mv $APP_STATE_DIR.before-restore-[0-9-]* $APP_STATE_DIR" "$WORK/restore2.out" \
        && [[ $(cat "$APP_STATE_DIR".before-restore-*/vpn.conf) == "VPN_PORT=1194" ]]
)

# --- SFTP (1.2.5): « keys only » really checked, resume checked, keys in one go ---

sftp_keys_only_checked() (
    sftp_load
    SEEDBOX_SFTP_PASSWORD=no
    mkdir -p "$SFTP_KEYS_DIR"
    echo "ssh-ed25519 AAAAone laptop" >"$SFTP_KEYS_DIR/lancelot"
    # an earlier Match block allows the password again for the account
    sshd() { if [[ $1 == -T ]]; then sshd_rule_in_force | sed 's/^passwordauthentication no$/passwordauthentication yes/'; fi; }
    if (seedbox_apply_sftp) &>"$WORK/sftp.out"; then return 1; fi
    grep -qxF "usermod --expiredate 1 lancelot" "$WORK/user-calls" || return 1
    # or keyboard-interactive (a password by another way)
    : >"$WORK/user-calls"
    rm -f "$WORK/expiry"
    sshd() { if [[ $1 == -T ]]; then sshd_rule_in_force | sed 's/^kbdinteractiveauthentication no$/kbdinteractiveauthentication yes/'; fi; }
    if (seedbox_apply_sftp) &>"$WORK/sftp.out"; then return 1; fi
    grep -qxF "usermod --expiredate 1 lancelot" "$WORK/user-calls"
)

sftp_resume_checked() (
    sftp_load
    sshd() { if [[ $1 == -T ]]; then sshd_rule_in_force; fi; }
    # suspended, and the account database refuses the change
    printf 1 >"$WORK/expiry"
    usermod() { echo "usermod $*" >>"$WORK/user-calls"; }
    if (seedbox_apply_sftp) &>"$WORK/sftp.out"; then
        cat "$WORK/sftp.out"
        return 1
    fi
    cat "$WORK/sftp.out"
    grep -q "could not be reactivated" "$WORK/sftp.out"
)

sftp_keys_load() {
    sftp_load
    SFTP_KEYS_DIR="$WORK/keys-$1"
    rm -rf "$SFTP_KEYS_DIR"
    mkdir -p "$SFTP_KEYS_DIR"
    seedbox_apply_sftp() { :; }
    seedbox_save() { :; }
    # a key is valid if it looks like one
    ssh-keygen() { [[ $(cat) == "ssh-ed25519 AAAA"* ]]; }
}

sftp_keys_import_all_or_nothing() (
    sftp_keys_load import
    : >"$SFTP_KEYS_DIR/lancelot"
    printf '%s\n' "ssh-ed25519 AAAAone laptop" "ssh-ed25519 AAAAtwo phone" "not a key" >"$WORK/keys.txt"
    if (sftp_keys_import "$WORK/keys.txt") &>"$WORK/keys.out"; then return 1; fi
    # the third key is invalid: none was added
    [[ ! -s $SFTP_KEYS_DIR/lancelot ]] || return 1
    # all valid: all added, in one go
    printf '%s\n' "ssh-ed25519 AAAAone laptop" "ssh-ed25519 AAAAtwo phone" >"$WORK/keys.txt"
    sftp_keys_import "$WORK/keys.txt" &>"$WORK/keys.out" || return 1
    [[ $(<"$SFTP_KEYS_DIR/lancelot") == $'ssh-ed25519 AAAAone laptop\nssh-ed25519 AAAAtwo phone' ]] \
        && [[ $(stat -c %a "$SFTP_KEYS_DIR/lancelot") == 644 ]]
)

sftp_keys_remove_failure_keeps_file() (
    sftp_keys_load remove
    printf '%s\n' "ssh-ed25519 AAAAone laptop" "ssh-ed25519 AAAAtwo phone" >"$SFTP_KEYS_DIR/lancelot"
    # the disk is full: the new content cannot be written
    cat() { return 1; }
    mv() { return 1; }
    if (sftp_keys_remove 1) &>"$WORK/keys.out"; then return 1; fi
    unset -f cat mv
    [[ $(<"$SFTP_KEYS_DIR/lancelot") == $'ssh-ed25519 AAAAone laptop\nssh-ed25519 AAAAtwo phone' ]] \
        && ! ls "$SFTP_KEYS_DIR"/.keys.* &>/dev/null
)

rename_group_undo_checked() (
    sftp_load
    SFTP_KEYS_DIR="$WORK/rename-keys2"
    mkdir -p "$SFTP_KEYS_DIR"
    touch "$SFTP_KEYS_DIR/lancelot"
    seedbox_save() { echo "save" >>"$WORK/user-calls"; }
    seedbox_apply() { echo "apply" >>"$WORK/user-calls"; }
    # the group is renamed, the keys cannot be moved, and the group cannot
    # get its old name back
    groupmod() {
        echo "groupmod $*" >>"$WORK/user-calls"
        [[ $2 == galahad ]]
    }
    mv() { return 1; }
    if (seedbox_set_credentials galahad) &>"$WORK/rename.out"; then return 1; fi
    cat "$WORK/rename.out" "$WORK/user-calls"
    # said, with what to type; the account stays suspended
    grep -q "groupmod --new-name lancelot galahad" "$WORK/rename.out" \
        && [[ $(<"$WORK/expiry") == 1 ]] && ! grep -qx "save\|apply" "$WORK/user-calls"
)

# --- restore (1.2.5): no link, no code in the settings ------------------------

# restore_archive_load NAME — a backup made of $WORK/NAME-root, and the restore
# stopped at its last question (« no »)
restore_archive_load() {
    load
    RESTORE_ROOT="$WORK/$1-root"
    rm -rf "$RESTORE_ROOT"
    mkdir -p "$RESTORE_ROOT/etc/seedtunnel"
    echo "VPN_PORT=51820" >"$RESTORE_ROOT/etc/seedtunnel/vpn.conf"
    # a client, as the VPN writes it: settings for bash, and its WireGuard file
    mkdir -p "$RESTORE_ROOT/etc/seedtunnel/vpn/clients"
    (
        CLIENT_NUMBER=2
        CLIENT_PUBLIC_KEY="x/y+z="
        state_write "$RESTORE_ROOT/etc/seedtunnel/vpn/clients/laptop.env" CLIENT_NUMBER CLIENT_PUBLIC_KEY
    )
    printf '[Interface]\nPrivateKey = a/b+c=\nAddress = 10.8.0.2/32\nDNS = 9.9.9.9, 1.1.1.1\n' \
        >"$RESTORE_ROOT/etc/seedtunnel/vpn/clients/laptop.conf"
    echo "a test passphrase" >"$WORK/$1-passphrase"
    chmod 600 "$WORK/$1-passphrase"
    OPT_PASSPHRASE_FILE="$WORK/$1-passphrase"
    APP_STATE_DIR="$WORK/$1-state"
    mkdir -p "$APP_STATE_DIR"
    confirm() { return 1; }
}

restore_archive_make() {
    local -a paths
    # as backup_paths gives them: etc/seedtunnel, etc/letsencrypt…
    mapfile -t paths < <(cd "$RESTORE_ROOT" && printf '%s\n' etc/*)
    tar -czf - -C "$RESTORE_ROOT" "${paths[@]}" | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
        -pass pass:"a test passphrase" -out "$WORK/$1.enc"
}

restore_refuses_links() (
    restore_archive_load links
    mkdir -p "$RESTORE_ROOT/etc/seedtunnel/vpn/clients"
    ln -s /etc/shadow "$RESTORE_ROOT/etc/seedtunnel/vpn/clients/phone.conf"
    restore_archive_make links
    if (restore_main "$WORK/links.enc") >"$WORK/links.out" 2>&1; then return 1; fi
    cat "$WORK/links.out"
    grep -q "is a link or a special file" "$WORK/links.out"
)

restore_accepts_letsencrypt_links() (
    restore_archive_load le
    mkdir -p "$RESTORE_ROOT/etc/letsencrypt/archive/seedbox.example.org" "$RESTORE_ROOT/etc/letsencrypt/live/seedbox.example.org"
    echo cert >"$RESTORE_ROOT/etc/letsencrypt/archive/seedbox.example.org/cert1.pem"
    ln -s ../../archive/seedbox.example.org/cert1.pem "$RESTORE_ROOT/etc/letsencrypt/live/seedbox.example.org/cert.pem"
    restore_archive_make le
    # goes as far as the last question
    (restore_main "$WORK/le.enc") >"$WORK/le.out" 2>&1
    cat "$WORK/le.out"
    ! grep -q "refused" "$WORK/le.out" && grep -q "The backup contains" "$WORK/le.out"
)

restore_accepts_real_backup() (
    restore_archive_load real
    restore_archive_make real
    # the WireGuard files of the clients are not settings read by bash
    (restore_main "$WORK/real.enc") >"$WORK/real.out" 2>&1
    cat "$WORK/real.out"
    ! grep -q "refused" "$WORK/real.out" && grep -q "The backup contains" "$WORK/real.out"
)

restore_refuses_code_in_client() (
    restore_archive_load client
    printf 'CLIENT_NUMBER=2;touch\n' >>"$RESTORE_ROOT/etc/seedtunnel/vpn/clients/laptop.env"
    restore_archive_make client
    if (restore_main "$WORK/client.enc") >"$WORK/client.out" 2>&1; then return 1; fi
    cat "$WORK/client.out"
    grep -q "laptop.env holds something else" "$WORK/client.out"
)

restore_refuses_code_in_settings() (
    restore_archive_load code
    printf 'VPN_PORT=$(touch %s/pwned)\n' "$WORK" >"$RESTORE_ROOT/etc/seedtunnel/vpn.conf"
    rm -f "$WORK/pwned"
    restore_archive_make code
    if (restore_main "$WORK/code.enc") >"$WORK/code.out" 2>&1; then return 1; fi
    cat "$WORK/code.out"
    grep -q "could run commands" "$WORK/code.out" && [[ ! -e $WORK/pwned ]]
)

state_files_round_trip_safe() (
    load
    local file="$WORK/round-trip.conf"
    A="a b" B='$6$salt$hash/x.y' C="quote\"s and 'single'" D="" E='$(touch nothing)' F="~root"
    state_write "$file" A B C D E F
    state_file_is_safe "$file" || return 1
    for bad in 'X=$(id)' 'X=`id`' 'X=a;id' 'X=~root' 'X=a b' 'id'; do
        printf '%s\n' "$bad" >"$WORK/bad.conf"
        if state_file_is_safe "$WORK/bad.conf"; then
            echo "accepted: $bad"
            return 1
        fi
    done
)

# --- backup (1.2.5): never a mix of two states, never an older backup replaced ----

backup_consistency_load() {
    load
    BACKUP_PASSPHRASE="a test passphrase"
    SETTINGS="$WORK/consistency/etc-seedtunnel"
    rm -rf "$WORK/consistency"
    mkdir -p "$SETTINGS" "$WORK/consistency/out"
    echo "VPN_PORT=51820" >"$SETTINGS/vpn.conf"
    : >"$WORK/attempts"
}

backup_redone_when_settings_change() (
    backup_consistency_load
    # the first archive is written while a setting changes (a restore, certbot…)
    tar() {
        if [[ $1 == -czf ]]; then
            echo attempt >>"$WORK/attempts"
            if (($(wc -l <"$WORK/attempts") == 1)); then echo "VPN_PORT=1194" >"$SETTINGS/vpn.conf"; fi
        fi
        command tar "$@"
    }
    backup_create_archive "$WORK/consistency/out/b.enc" "${SETTINGS#/}" &>/dev/null || return 1
    (($(wc -l <"$WORK/attempts") == 2)) || return 1
    # always changing: no archive kept, nothing left behind
    rm -f "$WORK/consistency/out/b.enc"
    : >"$WORK/attempts"
    tar() {
        if [[ $1 == -czf ]]; then echo "VPN_PORT=$RANDOM" >"$SETTINGS/vpn.conf"; fi
        command tar "$@"
    }
    if backup_create_archive "$WORK/consistency/out/b.enc" "${SETTINGS#/}" &>/dev/null; then return 1; fi
    [[ -z $(ls -A "$WORK/consistency/out") ]]
)

backup_never_replaces_older() (
    backup_consistency_load
    echo "older backup" >"$WORK/consistency/out/b.enc"
    if backup_create_archive "$WORK/consistency/out/b.enc" "${SETTINGS#/}" &>/dev/null; then return 1; fi
    [[ $(<"$WORK/consistency/out/b.enc") == "older backup" ]] || return 1
    # refused at once by « seedtunnel backup --output »
    backup_require_something() { :; }
    clear() { :; }
    OPT_OUTPUT_FILE="$WORK/consistency/out/b.enc"
    if (backup_main) &>"$WORK/consistency.out"; then return 1; fi
    grep -q "already exists" "$WORK/consistency.out" && [[ $(<"$WORK/consistency/out/b.enc") == "older backup" ]]
)

backup_passphrase_saved_whole() (
    load
    BACKUP_PASSPHRASE_FILE="$WORK/auto.passphrase"
    echo "the old passphrase" >"$BACKUP_PASSPHRASE_FILE"
    backup_require_something() { :; }
    backup_read_passphrase() { BACKUP_PASSPHRASE="the new passphrase"; }
    backup_auto_install_units() { :; }
    clear() { :; }
    # the disk is full when the new passphrase is written
    printf() {
        if [[ ${2-} == "the new passphrase" ]]; then return 1; fi
        builtin printf "$@"
    }
    if (backup_auto_enable) &>"$WORK/auto.out"; then return 1; fi
    unset -f printf
    [[ $(<"$BACKUP_PASSPHRASE_FILE") == "the old passphrase" && ! -e $BACKUP_PASSPHRASE_FILE.tmp ]]
)

# --- every question of the menus can be left with an empty answer ----------------
# (answers_load: the answers typed, in order; a question too many = no way out)

back_load() {
    load
    answers_load
    clear() { :; }
    : >"$WORK/back-calls"
    # what must not happen after going back
    pause() { echo "pause" >>"$WORK/back-calls"; }
    VPN_CLIENTS_DIR="$WORK/back-clients"
    rm -rf "$VPN_CLIENTS_DIR"
    mkdir -p "$VPN_CLIENTS_DIR"
    VPN_PUBLIC_ADDRESS=203.0.113.10
    VPN_PORT=51820
    VPN_DNS=9.9.9.9
    SEEDBOX_LETSENCRYPT=auto
    SEEDBOX_LETSENCRYPT_SERVER=production
}

back_nothing_done() {
    if [[ -s $WORK/back-calls ]]; then
        cat "$WORK/back-calls"
        return 1
    fi
}

vpn_add_client_can_go_back() (
    back_load
    vpn_load() { :; }
    vpn_installed() { return 0; }
    service_state() { echo running; }
    vpn_count_clients() { echo 0; }
    vpn_connected_count() { echo 0; }
    vpn_add_client() { echo "add $1" >>"$WORK/back-calls"; }
    # « Add a client », an empty name, then Q
    answers "1" "" "b"
    vpn_menu >/dev/null 2>&1 || return 1
    back_nothing_done || return 1
    # a wrong name is asked again, then empty: back
    answers "not valid!" ""
    vpn_ask_client_name name "" >/dev/null 2>&1
    (($? == 1))
)

vpn_client_actions_can_go_back() (
    back_load
    vpn_load() { :; }
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    service_state() { echo running; }
    vpn_count_clients() { echo 1; }
    vpn_connected_count() { echo 0; }
    touch "$VPN_CLIENTS_DIR/laptop.env"
    vpn_client_names() { echo laptop; }
    vpn_show_client() { echo "show $1" >>"$WORK/back-calls"; }
    vpn_share_client() { echo "share $1" >>"$WORK/back-calls"; }
    vpn_remove_client() { echo "revoke $1" >>"$WORK/back-calls"; }
    # show, link, revoke: empty answer each time; revoke: « no » too
    answers "2" "" "3" "" "4" "" "4" "laptop" "b"
    confirm() { return 1; }
    vpn_menu >/dev/null 2>&1 || return 1
    back_nothing_done
)

vpn_pick_client_asks_again() (
    back_load
    touch "$VPN_CLIENTS_DIR/laptop.env"
    vpn_client_names() { echo laptop; }
    # a number that does not exist is asked again
    answers "9" "laptop"
    vpn_pick_client name "Client" >/dev/null 2>&1 && [[ $name == laptop ]] || return 1
    answers ""
    vpn_pick_client name "Client" >/dev/null 2>&1
    (($? == 1))
)

vpn_settings_can_go_back() (
    back_load
    vpn_port_is_free() { return 0; }
    vpn_apply() { echo "apply" >>"$WORK/back-calls"; }
    VPN_PUBLIC_ADDRESS=203.0.113.10
    VPN_PORT=51820
    # empty address
    answers ""
    vpn_change_settings >/dev/null 2>&1 && return 1
    # empty port, empty choice of DNS
    answers "203.0.113.10" ""
    vpn_change_settings >/dev/null 2>&1 && return 1
    answers "203.0.113.10" "51820" ""
    vpn_change_settings >/dev/null 2>&1 && return 1
    # « no » to « Is that right? »
    confirm() { return 1; }
    answers "203.0.113.10" "51820" "1"
    vpn_change_settings >/dev/null 2>&1 && return 1
    back_nothing_done
)

vpn_install_can_go_back() (
    back_load
    vpn_check_kernel() { :; }
    base_setup() { :; }
    public_ipv4() { echo 203.0.113.10; }
    default_interface() { echo eth0; }
    seedbox_installed() { return 1; }
    vpn_port_is_free() { return 0; }
    vpn_apply() { echo "apply" >>"$WORK/back-calls"; }
    vpn_add_client() { echo "add $1" >>"$WORK/back-calls"; }
    answers ""
    vpn_install_interactive >/dev/null 2>&1 || return 1
    # the name of the first client, empty
    answers "203.0.113.10" "51820" "1" ""
    confirm() { return 0; }
    vpn_install_interactive >/dev/null 2>&1 || return 1
    back_nothing_done
)

seedbox_install_can_go_back() (
    back_load
    seedbox_check_web_ports() { :; }
    base_setup() { :; }
    apt_install() { :; }
    public_ipv4() { echo 203.0.113.10; }
    seedbox_guess_domain() { echo 203.0.113.10; }
    seedbox_default_data_dir() { echo "$WORK/data"; }
    seedbox_check_data_dir() { return 0; }
    ask_password() { printf -v "$1" '%s' 'a password of 20 chars'; }
    seedbox_apply() { echo "apply" >>"$WORK/back-calls"; }
    id() { return 1; }
    # empty user, then empty domain, then empty data folder
    answers ""
    seedbox_install_interactive >/dev/null 2>&1 || return 1
    answers "lancelot" ""
    seedbox_install_interactive >/dev/null 2>&1 || return 1
    answers "lancelot" "203.0.113.10" ""
    seedbox_install_interactive >/dev/null 2>&1 || return 1
    # « no » to « Start the installation? »: nothing, and no password left
    confirm() { return 1; }
    answers "lancelot" "203.0.113.10" "$WORK/data"
    seedbox_install_interactive >/dev/null 2>&1 || return 1
    [[ -z ${SEEDBOX_NEW_PASSWORD-} ]] && back_nothing_done
)

seedbox_credentials_can_go_back() (
    back_load
    SEEDBOX_USER=lancelot
    ask_password() { printf -v "$1" '%s' 'a password of 20 chars'; }
    seedbox_set_credentials() { echo "set $1" >>"$WORK/back-calls"; }
    answers ""
    seedbox_change_credentials >/dev/null 2>&1 && return 1
    # « no » to the last question
    confirm() { return 1; }
    answers "lancelot"
    seedbox_change_credentials >/dev/null 2>&1 && return 1
    [[ -z ${SEEDBOX_NEW_PASSWORD-} ]] && back_nothing_done
)

sftp_keys_menu_can_go_back() (
    back_load
    seedbox_load() { :; }
    SEEDBOX_USER=lancelot
    SEEDBOX_SFTP_PASSWORD=yes
    SFTP_KEYS_DIR="$WORK/back-keys"
    mkdir -p "$SFTP_KEYS_DIR"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEWuSJMjcPMEGcGPXYQTMQwKBZWAmPq5xBrlCvTXnDEn laptop" >"$SFTP_KEYS_DIR/lancelot"
    sftp_keys_import() { echo "import" >>"$WORK/back-calls"; }
    sftp_keys_remove() { echo "remove $1" >>"$WORK/back-calls"; }
    # add: a wrong key asked again, then empty; remove: a wrong number, then empty
    answers "1" "not a key" "" "3" "5" "" "b"
    sftp_keys_menu >/dev/null 2>&1 || return 1
    back_nothing_done
)

unban_can_go_back() (
    back_load
    fail2ban_bans_print() { :; }
    fail2ban_unban() { echo "unban $1" >>"$WORK/back-calls"; }
    # a wrong address is asked again, then empty
    answers "x;y" ""
    fail2ban_bans_menu >/dev/null 2>&1 || return 1
    back_nothing_done
)

seedbox_domain_install_can_go_back() (
    back_load
    SEEDBOX_DOMAIN=203.0.113.10
    answers ""
    seedbox_ask_domain 203.0.113.10 >/dev/null 2>&1
    (($? == 1))
)

backup_passphrase_can_go_back() (
    load
    OPT_PASSPHRASE_FILE=""
    stdin_is_terminal() { return 0; }
    # empty at once
    backup_read_passphrase 1 <<<"" >/dev/null 2>&1
    (($? == 1)) || return 1
    # too short, then empty
    backup_read_passphrase 1 >/dev/null 2>&1 <<<$'short\n'
    (($? == 1)) || return 1
    # typed twice differently, then empty
    backup_read_passphrase 1 >/dev/null 2>&1 <<<$'a long passphrase\nanother passphrase\n'
    (($? == 1)) || return 1
    # typed twice the same: kept
    backup_read_passphrase 1 >/dev/null 2>&1 <<<$'a long passphrase\na long passphrase'
    [[ $BACKUP_PASSPHRASE == "a long passphrase" ]]
)

backup_create_and_weekly_can_go_back() (
    back_load
    OPT_PASSPHRASE_FILE=""
    stdin_is_terminal() { return 0; }
    BACKUP_DIR="$WORK/back-backups"
    BACKUP_PASSPHRASE_FILE="$WORK/back-passphrase"
    rm -f "$BACKUP_PASSPHRASE_FILE"
    backup_auto_status() { :; }
    backup_require_something() { :; }
    backup_auto_enabled() { return 1; }
    backup_write() { echo "backup $1" >>"$WORK/back-calls"; }
    backup_auto_install_units() { echo "weekly on" >>"$WORK/back-calls"; }
    # « backup now », then « weekly backup on »: empty passphrase both times
    answers "1" "3" "b"
    backup_menu >/dev/null 2>&1 <<<$'\n\n' || return 1
    back_nothing_done && [[ ! -e $BACKUP_PASSPHRASE_FILE ]]
)

backup_menu_can_go_back() (
    back_load
    backup_auto_status() { :; }
    backup_list() { :; }
    backup_latest() { echo "$WORK/none.enc"; }
    restore_main() { echo "restore $1" >>"$WORK/back-calls"; }
    # restore: a file that does not exist asked again, then empty
    answers "4" "$WORK/none.enc" "" "b"
    backup_menu >/dev/null 2>&1 || return 1
    back_nothing_done
)

restore_wrong_passphrase_asked_again() (
    load
    local root="$WORK/restore3-root"
    rm -rf "$root" "$WORK/restore3-state"*
    mkdir -p "$root/etc/seedtunnel"
    echo "VPN_PORT=51820" >"$root/etc/seedtunnel/vpn.conf"
    tar -czf - -C "$root" etc/seedtunnel | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
        -pass pass:"a test passphrase" -out "$WORK/restore3.enc"
    OPT_PASSPHRASE_FILE=""
    stdin_is_terminal() { return 0; }
    APP_STATE_DIR="$WORK/restore3-state"
    mkdir -p "$APP_STATE_DIR"
    echo "VPN_PORT=1194" >"$APP_STATE_DIR/vpn.conf"
    # a wrong passphrase: asked again; then empty: back, nothing touched
    restore_main "$WORK/restore3.enc" >"$WORK/restore3.out" 2>&1 <<<$'wrong passphrase\n'
    rc=$?
    cat "$WORK/restore3.out"
    ((rc == 1)) && grep -q "Cannot decrypt" "$WORK/restore3.out" \
        && [[ $(<"$APP_STATE_DIR/vpn.conf") == "VPN_PORT=1194" && -z $BACKUP_TMP_DIR ]]
)

# --- 1.2.6: reliability --------------------------------------------------------------

# Runs bash code with the libraries loaded and the options of seedtunnel.sh
# (set -e: an unhandled failure stops everything), in a process of its own:
# inside a test, « set -e » would be ignored (tests run in a condition)
strict() {
    ROOT=$ROOT WORK=$WORK bash -c "set -Eeuo pipefail; $(declare -f load); load; $1"
}

df_failure_does_not_stop() (
    strict '
        df() { return 1; }
        sysctl() { echo 0; }
        timedatectl() { echo yes; }
        logger() { :; }
        seedbox_installed() { return 0; }
        SEEDBOX_DATA_DIR=/srv/seedbox
        free=$(disk_free_gb /)
        [[ -z $free ]]
        doctor_system
        diskguard_check
        diskguard_prestart
        echo "reached the end"' >"$WORK/df.out" 2>&1
    cat "$WORK/df.out"
    grep -q "reached the end" "$WORK/df.out" && grep -q "Free space of / unreadable" "$WORK/df.out"
)

net_hardening_checked_everywhere() (
    load
    NET_HARDENING_FILE="$WORK/90-network.conf"
    # the server has IPv6
    NET_HARDENING_IPV6_DIR=$WORK
    net_hardening_generate >"$NET_HARDENING_FILE"
    chown() { :; }
    : >"$WORK/sysctl-loads"
    # every value is 0, except the IPv6 redirects, still accepted until loaded
    sysctl() {
        local key
        shift
        for key in "$@"; do
            if [[ $key == net.ipv6.conf.all.accept_redirects && ! -s $WORK/sysctl-loads ]]; then echo 1; else echo 0; fi
        done
    }
    net_hardening_load() { echo load >>"$WORK/sysctl-loads"; }
    timedatectl() { echo yes; }
    DOCTOR_WARNINGS=0
    doctor_system >"$WORK/hardening.out" 2>&1
    cat "$WORK/hardening.out"
    grep -q "settings not applied" "$WORK/hardening.out" || return 1
    # the file did not change, yet the settings are loaded again
    net_hardening_apply >>"$WORK/hardening.out" 2>&1
    (($(wc -l <"$WORK/sysctl-loads") == 1)) || return 1
    # all in force: nothing loaded again
    net_hardening_apply >>"$WORK/hardening.out" 2>&1
    (($(wc -l <"$WORK/sysctl-loads") == 1))
)

doctor_nat_checks_interface() (
    load
    VPN_PORT=51820
    VPN_PUBLIC_ADDRESS=203.0.113.10
    systemctl() { return 0; }
    wg() { echo 51820; }
    sysctl() { echo 1; }
    vpn_count_clients() { echo 1; }
    vpn_connected_count() { echo 0; }
    # the rules were made when the network interface was eth0; it is ens3 now
    nft() { printf '%s\n' 'table ip seedtunnel {' '	chain postrouting {' '		ip saddr 10.8.0.0/24 oifname "eth0" masquerade' '	}' '}'; }
    default_interface() { echo ens3; }
    DOCTOR_ERRORS=0
    doctor_vpn 203.0.113.10 >"$WORK/nat.out" 2>&1
    cat "$WORK/nat.out"
    ((DOCTOR_ERRORS == 1)) && grep -q "network interface of the server (ens3)" "$WORK/nat.out" || return 1
    # made for the interface in use: fine
    default_interface() { echo eth0; }
    DOCTOR_ERRORS=0
    doctor_vpn 203.0.113.10 &>/dev/null
    ((DOCTOR_ERRORS == 0))
)

firewall_policy_checked() (
    load
    FIREWALL_CONF_FILE="$WORK/fw-policy.conf"
    FIREWALL_ENABLED=1
    state_write "$FIREWALL_CONF_FILE" FIREWALL_ENABLED
    firewall_summary() { echo SSH; }
    firewall_sshd_ports() { echo 22; }
    systemctl() { return 1; }
    # the table is there, but its input chain accepts everything
    POLICY=accept
    nft() { printf '%s\n' 'table inet seedtunnel_fw {' '	chain input {' "		type filter hook input priority filter; policy $POLICY;" '		tcp dport { 22 } accept' '	}' '}'; }
    DOCTOR_ERRORS=0
    doctor_firewall >"$WORK/policy.out" 2>&1
    firewall_status >>"$WORK/policy.out" 2>&1
    cat "$WORK/policy.out"
    ((DOCTOR_ERRORS == 1)) && (($(grep -c "do not refuse" "$WORK/policy.out") == 2)) || return 1
    # everything not allowed is refused: fine
    POLICY=drop
    DOCTOR_ERRORS=0
    doctor_firewall &>/dev/null
    ((DOCTOR_ERRORS == 0))
)

doctor_weekly_backup_needs() (
    load
    BACKUP_DIR="$WORK/doctor-auto"
    mkdir -p "$BACKUP_DIR"
    touch "$BACKUP_DIR/server-auto.tar.gz.enc"
    BACKUP_PASSPHRASE_FILE="$WORK/doctor-auto.passphrase"
    BACKUP_DOWNLOADED_MARK="$WORK/doctor-auto.mark"
    touch "$BACKUP_DOWNLOADED_MARK"
    backup_auto_enabled() { return 0; }
    # the timer is stopped, and the passphrase can be read by everyone
    systemctl() { return 1; }
    echo "a test passphrase" >"$BACKUP_PASSPHRASE_FILE"
    chmod 644 "$BACKUP_PASSPHRASE_FILE"
    DOCTOR_ERRORS=0
    doctor_backup >"$WORK/auto-needs.out" 2>&1
    cat "$WORK/auto-needs.out"
    ((DOCTOR_ERRORS == 2)) && grep -q "timer is stopped" "$WORK/auto-needs.out" \
        && grep -q "read by others" "$WORK/auto-needs.out" || return 1
    # no passphrase at all
    rm -f "$BACKUP_PASSPHRASE_FILE"
    doctor_backup >"$WORK/auto-needs.out" 2>&1
    grep -q "passphrase of the weekly backup is missing" "$WORK/auto-needs.out" || return 1
    # all there: no error
    systemctl() { [[ $1 == is-active ]]; }
    echo "a test passphrase" >"$BACKUP_PASSPHRASE_FILE"
    chmod 600 "$BACKUP_PASSPHRASE_FILE"
    DOCTOR_ERRORS=0
    doctor_backup &>/dev/null
    ((DOCTOR_ERRORS == 0))
)

doctor_reports_unfinished_update() (
    load
    APP_DIR="$WORK/app-unfinished/seedtunnel"
    mkdir -p "$APP_DIR.previous"
    timedatectl() { echo yes; }
    doctor_system >"$WORK/unfinished.out" 2>&1
    cat "$WORK/unfinished.out"
    grep -q "did not finish" "$WORK/unfinished.out" && grep -q "rm -rf $APP_DIR.previous" "$WORK/unfinished.out"
)

# certbot, the full disk protection, the weekly backup and the firewall at
# boot: enabled and running after the next run, nothing done when they are
services_put_right() (
    load
    chown() { :; }
    rm -f "$WORK"/units-*
    DISKGUARD_SERVICE="$WORK/units-dg.service"
    DISKGUARD_TIMER="$WORK/units-dg.timer"
    BACKUP_SERVICE="$WORK/units-bk.service"
    BACKUP_TIMER="$WORK/units-bk.timer"
    FIREWALL_CONF_FILE="$WORK/units-fw.conf"
    FIREWALL_RULES="$WORK/units-fw.nft"
    FIREWALL_UNIT="$WORK/units-fw.service"
    FIREWALL_ENABLED=1
    state_write "$FIREWALL_CONF_FILE" FIREWALL_ENABLED
    firewall_generate_rules() { echo rules; }
    echo rules >"$FIREWALL_RULES"
    nft() { :; }
    SEEDBOX_DOMAIN=seedbox.example.org
    SEEDBOX_LETSENCRYPT=auto
    SEEDBOX_LETSENCRYPT_SERVER=production
    seedbox_selfsigned_ensure() { :; }
    letsencrypt_usable() { return 0; }
    seedbox_certificate_mode() { echo letsencrypt; }
    seedbox_apply_nginx() { :; }
    systemctl() {
        case $1 in
            is-enabled) [[ $UNITS_ENABLED == *" ${*: -1} "* ]] ;;
            is-active) [[ $UNITS_ACTIVE == *" ${*: -1} "* ]] ;;
            *) echo "systemctl $*" >>"$WORK/units" ;;
        esac
    }
    services_apply() {
        : >"$WORK/units"
        seedbox_apply_https && diskguard_install && backup_auto_install_units && firewall_refresh
    }
    # after a restart: the timers of the certificate and of the disk ran but
    # were not enabled at boot; the backup timer and the firewall are enabled
    # but stopped
    UNITS_ENABLED=" seedtunnel-backup.timer seedtunnel-firewall.service "
    UNITS_ACTIVE=" certbot.timer seedtunnel-diskguard.timer "
    services_apply >"$WORK/units.out" 2>&1 || {
        cat "$WORK/units.out"
        return 1
    }
    cat "$WORK/units"
    grep -qx "systemctl enable --now certbot.timer" "$WORK/units" \
        && grep -qx "systemctl enable --now seedtunnel-diskguard.timer" "$WORK/units" \
        && grep -qx "systemctl start seedtunnel-backup.timer" "$WORK/units" \
        && grep -qx "systemctl start seedtunnel-firewall.service" "$WORK/units" || return 1
    # all in order: nothing is done
    UNITS_ENABLED=" certbot.timer seedtunnel-diskguard.timer seedtunnel-backup.timer seedtunnel-firewall.service "
    UNITS_ACTIVE=$UNITS_ENABLED
    services_apply >"$WORK/units.out" 2>&1 || return 1
    ! grep -E "enable|start" "$WORK/units"
)

vpn_enable_failure_said() (
    load
    VPN_PORT=51820
    wg-quick() { printf '[Interface]\n'; }
    nft() { return 0; }
    wg() { if [[ $1 == show ]]; then echo 51820; fi; }
    # running, not enabled at boot, and enabling it fails
    systemctl() { [[ $1 == is-active ]]; }
    vpn_reconcile 0 </dev/null >"$WORK/vpn-enable.out" 2>&1 || return 1
    cat "$WORK/vpn-enable.out"
    grep -q "could not be enabled at boot" "$WORK/vpn-enable.out"
)

diskguard_start_failure_said() (
    load
    DISKGUARD_MARKER="$WORK/diskguard.failed"
    SEEDBOX_DATA_DIR=$WORK
    seedbox_installed() { return 0; }
    : >"$WORK/dg-logger"
    logger() { echo "logger $*" >>"$WORK/dg-logger"; }
    disk_free_gb() { echo 50; }
    # stopped by the guard, room again, but Transmission does not start
    date +%s >"$DISKGUARD_MARKER"
    systemctl() { [[ $1 != start ]]; }
    diskguard_check >"$WORK/dg-start.out" 2>&1
    cat "$WORK/dg-start.out" "$WORK/dg-logger"
    # still marked (tried again at the next check), and said in the journal
    [[ -e $DISKGUARD_MARKER ]] && grep -q "does not start again" "$WORK/dg-logger" || return 1
    # the diagnostics say it does not start, not that the disk is full
    DOCTOR_ERRORS=0
    doctor_transmission >"$WORK/dg-doctor.out" 2>&1
    cat "$WORK/dg-doctor.out"
    ((DOCTOR_ERRORS == 1)) && grep -q "does not start again although there is room (50 GB free)" "$WORK/dg-doctor.out"
)

validators_stricter() (
    load
    local good bad
    # IPv4: no leading zero
    is_ipv4 10.0.0.1 && is_ipv4 0.0.0.0 && ! is_ipv4 010.0.0.1 && ! is_ipv4 1.2.3.04 && ! is_ipv4 00.1.2.3 || return 1
    # DNS: no comma at either end
    vpn_is_valid_dns "1.1.1.1, 1.0.0.1" && ! vpn_is_valid_dns "1.1.1.1," && ! vpn_is_valid_dns "1.1.1.1, " \
        && ! vpn_is_valid_dns ", 1.1.1.1" || return 1
    # public address of the VPN: IPv4, IPv6 or domain name
    for good in 203.0.113.10 2001:db8::1 vpn.example.org VPN.Example.org; do
        vpn_is_valid_address "$good" || {
            echo "refused: $good"
            return 1
        }
    done
    for bad in 1.2.3 300.1.1.1 a..b example -vpn.example.org vpn.example.org. 2001:::1 "a b" 010.0.0.1; do
        if vpn_is_valid_address "$bad"; then
            echo "accepted: $bad"
            return 1
        fi
    done
)

update_git_tag_checked() (
    load
    # the code of the tag v9.9.9 says another version
    UPDATE_TAG_CODE_VERSION=1.0.0
    update_git_make
    # and a tag that is not a version
    git -C "$APP_DIR" tag v9.9.10-test v9.9.9
    git() {
        if fetch_stub "$@"; then return 0; fi
        command git "$@"
    }
    (update_from_git) >"$WORK/update-tags.out" 2>&1
    cat "$WORK/update-tags.out"
    # nothing switched, nothing applied
    [[ $(command git -C "$APP_DIR" rev-parse HEAD) == "$UPDATE_OLD" && ! -e $WORK/app/applied ]] \
        && grep -q "Tag v9.9.9 left out: its code says version 1.0.0" "$WORK/update-tags.out"
)

language_asked_again() (
    load
    rm -f "$APP_LANG_FILE"
    SEEDTUNNEL_LANG=""
    # an answer other than 1 or 2 is asked again
    language_first_run <<<$'3\nfrench\n2' >/dev/null 2>&1
    [[ $(<"$APP_LANG_FILE") == fr ]] || return 1
    # a file that holds something else: the question is asked
    echo xx >"$APP_LANG_FILE"
    language_first_run <<<'1' >/dev/null 2>&1
    [[ $(<"$APP_LANG_FILE") == en ]] || return 1
    # from the menu: asked again too; an empty answer goes back
    INTERACTIVE=1
    language_menu <<<$'9\n2' >/dev/null 2>&1
    [[ $(<"$APP_LANG_FILE") == fr ]] || return 1
    language_menu <<<'' >/dev/null 2>&1
    [[ $(<"$APP_LANG_FILE") == fr ]] || return 1
    # written aside, then renamed: a failure leaves the saved choice whole
    i18n_load en
    mv() { return 1; }
    language_save en >"$WORK/language.out" 2>&1
    unset -f mv
    [[ $(<"$APP_LANG_FILE") == fr && ! -e $APP_LANG_FILE.tmp ]] && grep -q "Cannot save the language" "$WORK/language.out"
)

shortcut_put_right() (
    load
    APP_SHORTCUT="$WORK/bin/seedtunnel"
    rm -rf "${WORK:?}/bin"
    mkdir -p "$WORK/bin"
    # missing: created
    install_shortcut
    [[ $(readlink "$APP_SHORTCUT") == "$ROOT/seedtunnel.sh" ]] || return 1
    # pointing to an older copy: put right
    ln -sfn /opt/old-copy/seedtunnel.sh "$APP_SHORTCUT"
    install_shortcut
    [[ $(readlink "$APP_SHORTCUT") == "$ROOT/seedtunnel.sh" ]] || return 1
    # a file of another program: left alone, and said
    rm -f "$APP_SHORTCUT"
    echo "another program" >"$APP_SHORTCUT"
    install_shortcut 2>"$WORK/shortcut.out"
    cat "$WORK/shortcut.out"
    [[ $(<"$APP_SHORTCUT") == "another program" ]] && grep -q "another program" "$WORK/shortcut.out"
)

# Before anything: not even the check of the system (root, Debian), which
# creates the folder of the settings
commands_refused_first() (
    local arguments out
    for arguments in "whatever" "apply now" "doctor x" "update x" "update back x" "language fr en" "restore a.enc b.enc" "diskguard-check x"; do
        # shellcheck disable=SC2086 # one word per argument
        if out=$(SEEDTUNNEL_LANG=en bash "$ROOT/seedtunnel.sh" $arguments 2>&1); then
            echo "accepted: $arguments"
            return 1
        fi
        if [[ $out != *"Unknown command"* && $out != *"Too many arguments"* && $out != *"Usage: seedtunnel update [back]"* ]]; then
            echo "$arguments → $out"
            return 1
        fi
    done
)

share_refused_without_room() (
    share_load room
    pgrep() { return 0; }
    # /run (in memory) is almost full
    df() { printf 'Avail\n%s\n' 1000; }
    if (share_create "$WORK/to-share" file.conf Title "" Note) &>"$WORK/share.out"; then
        cat "$WORK/share.out"
        return 1
    fi
    cat "$WORK/share.out"
    grep -q "Not enough room" "$WORK/share.out" && [[ -z $(find "$SHARE_DIR" -mindepth 1 2>/dev/null) ]]
)

# nginx takes the first expression of the map that matches the address
share_map_key() {
    local regex value
    while read -r regex value; do
        regex=${regex#\"~}
        regex=${regex%\"}
        if [[ $1 =~ $regex ]]; then
            printf '%s' "$value"
            return 0
        fi
    done < <(share_generate_nginx_http | sed -n '/^map \$uri \$seedtunnel_share_file {/,/^}/{/"~/p}')
}

share_page_not_limited() (
    load
    local token=0123456789abcdef0123456789abcdef
    # the page of a link (opened by the preview of a message) is not counted
    [[ $(share_map_key "/share/$token/index.html") == '"";' ]] || return 1
    # its file is: served once
    [[ $(share_map_key "/share/$token/phone.conf") == '$uri;' ]]
)

vpn_sync_checks_nat_first() (
    load
    : >"$WORK/sync-calls"
    wg-quick() { printf '[Interface]\n'; }
    wg() { echo "wg $1" >>"$WORK/sync-calls"; }
    # nftables refuses the NAT rules
    nft() {
        echo "nft $*" >>"$WORK/sync-calls"
        return 1
    }
    if vpn_sync </dev/null &>/dev/null; then return 1; fi
    cat "$WORK/sync-calls"
    ! grep -q "wg syncconf" "$WORK/sync-calls"
)

vpn_kernel_check_cleans_up() (
    load
    # left by a check cut short
    touch "$WORK/st-wgtest"
    ip() {
        case "$1 $2" in
            "link show") return 1 ;;
            "link del") rm -f "$WORK/st-wgtest" ;;
            "link add") [[ ! -e $WORK/st-wgtest ]] && touch "$WORK/st-wgtest" ;;
        esac
    }
    vpn_check_kernel >"$WORK/kernel.out" 2>&1 || {
        cat "$WORK/kernel.out"
        return 1
    }
    [[ ! -e $WORK/st-wgtest ]]
)

vpn_port_change_through_vpn() (
    back_load
    vpn_port_is_free() { return 0; }
    vpn_apply() { echo "apply" >>"$WORK/back-calls"; }
    : >"$WORK/questions"
    confirm() {
        echo "$1" >>"$WORK/questions"
        [[ $1 == 'Is that right?' ]]
    }
    # this session goes through the VPN
    SSH_CONNECTION="10.8.0.2 50000 10.8.0.1 22"
    VPN_PORT=51820
    # same address, new port, Quad9
    answers "203.0.113.10" "51821" "1"
    vpn_change_settings >"$WORK/port.out" 2>&1
    cat "$WORK/port.out" "$WORK/questions"
    # warned, asked (« no » by default), nothing applied
    grep -q "every client is disconnected" "$WORK/port.out" && grep -q "Change the port anyway?" "$WORK/questions" || return 1
    back_nothing_done || return 1
    # same port: not asked
    : >"$WORK/questions"
    VPN_PORT=51820
    answers "203.0.113.10" "51820" "1"
    vpn_change_settings >"$WORK/port.out" 2>&1 || return 1
    ! grep -q "anyway" "$WORK/questions" && grep -q apply "$WORK/back-calls"
)

firewall_message_says_rule() (
    firewall_trial_load
    # no new login: « yes » is refused, and the rule is said
    journalctl() { :; }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    (($(grep -c "through the VPN, only if this session goes through the VPN too" "$WORK/fw/out") == 2))
)

backup_new_passphrase_warns() (
    load
    BACKUP_DIR="$WORK/passphrase-backups"
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    touch "$BACKUP_DIR/seedtunnel-server-20261101-030000-auto.tar.gz.enc"
    BACKUP_PASSPHRASE_FILE="$WORK/new.passphrase"
    backup_require_something() { :; }
    backup_read_passphrase() { BACKUP_PASSPHRASE="the new passphrase"; }
    backup_auto_install_units() { :; }
    clear() { :; }
    backup_auto_enable >"$WORK/new-passphrase.out" 2>&1 || return 1
    cat "$WORK/new-passphrase.out"
    grep -q "already made keep the passphrase" "$WORK/new-passphrase.out" || return 1
    # no backup yet: nothing to say about older ones
    rm -f "$BACKUP_DIR"/*.enc
    backup_auto_enable >"$WORK/new-passphrase.out" 2>&1 || return 1
    ! grep -q "already made" "$WORK/new-passphrase.out"
)

i18n_check_stricter() (
    local copy="$WORK/i18n-copy"
    rm -rf "$copy"
    mkdir -p "$copy/tests"
    cp -r "$ROOT/seedtunnel.sh" "$ROOT/lib" "$ROOT/lang" "$copy/"
    cp "$ROOT/tests/i18n_check.py" "$copy/tests/"
    python3 "$copy/tests/i18n_check.py" >/dev/null || {
        echo "the copy as it is: refused"
        return 1
    }
    # a translation left empty (one without %s: the placeholders still match)
    awk 'done != 1 && /^en: / && !/%/ { print; getline; print "fr: "; done = 1; next } { print }' \
        "$ROOT/lang/fr.txt" >"$copy/lang/fr.txt"
    if python3 "$copy/tests/i18n_check.py" >"$WORK/i18n.out"; then
        echo "empty translation accepted"
        return 1
    fi
    # « 100 % »: printf would read the « % » as the start of a placeholder
    awk 'done != 1 && /^en: / && !/%/ { print; getline; print $0 " 100 %"; done = 1; next } { print }' \
        "$ROOT/lang/fr.txt" >"$copy/lang/fr.txt"
    if python3 "$copy/tests/i18n_check.py" >"$WORK/i18n.out"; then
        echo "stray % accepted"
        return 1
    fi
)

nginx_home_asks_password_first() (
    load
    SEEDBOX_DOMAIN=seedbox.example.org
    SEEDBOX_CERTIFICATE=letsencrypt
    local block
    block=$(nginx_generate_site | sed -n '/location = \/ {/,/}/p')
    echo "$block"
    # « return » would answer before nginx asks for the password
    [[ -n $block ]] && ! grep -q return <<<"$block"
)

backup_dates_in_words() (
    load
    BACKUP_DIR="$WORK/dates-backups"
    mkdir -p "$BACKUP_DIR"
    touch "$BACKUP_DIR/server-auto.tar.gz.enc"
    BACKUP_PASSPHRASE_FILE="$WORK/dates.passphrase"
    echo "a test passphrase" >"$BACKUP_PASSPHRASE_FILE"
    chmod 600 "$BACKUP_PASSPHRASE_FILE"
    BACKUP_DOWNLOADED_MARK="$WORK/dates.mark"
    touch "$BACKUP_DOWNLOADED_MARK"
    backup_auto_enabled() { return 0; }
    systemctl() { [[ $1 == is-active ]]; }
    doctor_backup >"$WORK/dates.out" 2>&1
    backup_auto_status >>"$WORK/dates.out" 2>&1
    cat "$WORK/dates.out"
    ! grep -q "day(s)" "$WORK/dates.out" && (($(grep -c "today" "$WORK/dates.out") == 3)) || return 1
    # yesterday, in French
    i18n_load fr
    touch -d '25 hours ago' "$BACKUP_DOWNLOADED_MARK"
    doctor_backup >"$WORK/dates.out" 2>&1
    cat "$WORK/dates.out"
    grep -q "commencé hier" "$WORK/dates.out" && grep -q "la dernière : aujourd'hui" "$WORK/dates.out"
)

# --- 1.2.7: a restore keeps the weekly backup working ----------------------------
# Seen on a real server: the weekly backup turned on, then a backup made
# before restored. The settings restored had no passphrase, the timer (not in
# the backup) kept running: every weekly backup would have failed.

restore_weekly_load() {
    restore_archive_load "$1"
    # a backup made before the weekly backup was turned on: no passphrase in it
    restore_archive_make "$1"
    BACKUP_PASSPHRASE_FILE="$APP_STATE_DIR/backup.passphrase"
    WEEKLY=$1
    # then the weekly backup turned on: its timer runs
    touch "$WORK/$1-timer-on"
    : >"$WORK/$1-calls"
    backup_auto_enabled() { [[ -e $WORK/$WEEKLY-timer-on ]]; }
    backup_auto_install_units() { echo units >>"$WORK/$WEEKLY-calls"; }
    backup_auto_disable() {
        echo disable >>"$WORK/$WEEKLY-calls"
        rm -f "$WORK/$WEEKLY-timer-on"
    }
    confirm() { return 0; }
    # messages in English, whatever an earlier test saved
    i18n_init() { i18n_load en; }
    # nothing else to put back here
    vpn_installed() { return 1; }
    seedbox_installed() { return 1; }
    firewall_enabled() { return 1; }
}

restore_keeps_weekly_passphrase() (
    restore_weekly_load weekly-kept
    echo "the weekly passphrase" >"$BACKUP_PASSPHRASE_FILE"
    chmod 600 "$BACKUP_PASSPHRASE_FILE"
    restore_main "$WORK/weekly-kept.enc" >"$WORK/weekly-kept.out" 2>&1 || {
        cat "$WORK/weekly-kept.out"
        return 1
    }
    cat "$WORK/weekly-kept.out" "$WORK/weekly-kept-calls"
    # its passphrase is still there, its timer still on, and it is said
    [[ -s $BACKUP_PASSPHRASE_FILE && $(<"$BACKUP_PASSPHRASE_FILE") == "the weekly passphrase" ]] \
        && grep -qx units "$WORK/weekly-kept-calls" && ! grep -q disable "$WORK/weekly-kept-calls" \
        && grep -q "is kept, with its passphrase" "$WORK/weekly-kept.out"
)

restore_weekly_without_passphrase_off() (
    restore_weekly_load weekly-none
    # the timer runs, but no passphrase anywhere: turned off, and said
    restore_main "$WORK/weekly-none.enc" >"$WORK/weekly-none.out" 2>&1 || {
        cat "$WORK/weekly-none.out"
        return 1
    }
    cat "$WORK/weekly-none.out" "$WORK/weekly-none-calls"
    grep -qx disable "$WORK/weekly-none-calls" && grep -q "it was turned off" "$WORK/weekly-none.out"
)

# --- 1.2.8: a restore checks the server first; firewall rules; report ---------------

# What a restore would do afterwards: only recorded (never run in a test)
restore_record_steps() {
    : >"$WORK/$1-steps"
    RESTORE_STEPS="$WORK/$1-steps"
    vpn_check_kernel() { echo kernel >>"$RESTORE_STEPS"; }
    base_setup() { echo base >>"$RESTORE_STEPS"; }
    vpn_apply() { echo vpn >>"$RESTORE_STEPS"; }
    seedbox_apply() { echo seedbox >>"$RESTORE_STEPS"; }
    restore_transmission_state() { :; }
    firewall_enable() { echo firewall >>"$RESTORE_STEPS"; }
    backup_auto_install_units() { :; }
    backup_auto_enabled() { return 1; }
    i18n_init() { i18n_load en; }
    RESTORE_MARKER="$APP_STATE_DIR.restore-unfinished"
    FIREWALL_CONF_FILE="$APP_STATE_DIR/firewall.conf"
    FIREWALL_RULES="$APP_STATE_DIR/firewall.nft"
    BACKUP_PASSPHRASE_FILE="$APP_STATE_DIR/backup.passphrase"
    confirm() {
        echo "asked" >>"$RESTORE_STEPS"
        return 0
    }
}

# Refused before the question, and nothing of this server changed
restore_refused_first() {
    local name=$1 message=$2
    printf 'SERVER=settings\n' >"$APP_STATE_DIR/server.conf"
    if (restore_main "$WORK/$name.enc") >"$WORK/$name.out" 2>&1; then
        cat "$WORK/$name.out"
        return 1
    fi
    cat "$WORK/$name.out" "$RESTORE_STEPS"
    grep -qF "$message" "$WORK/$name.out" && [[ ! -s $RESTORE_STEPS && -f $APP_STATE_DIR/server.conf && ! -e $RESTORE_MARKER ]]
}

restore_refuses_other_sftp_account() (
    restore_archive_load account
    printf 'SEEDBOX_USER=lancelot\n' >"$RESTORE_ROOT/etc/seedtunnel/seedbox.conf"
    restore_archive_make account
    restore_record_steps account
    # this server: a VPN, and a seedbox with the account neil
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    SEEDBOX_USER=neil
    restore_refused_first account "uses the account neil, the backup the account lancelot"
)

restore_refuses_existing_account() (
    restore_archive_load existing
    # an account this server already has (here, the one running the tests)
    printf 'SEEDBOX_USER=%s\n' "$(id -un)" >"$RESTORE_ROOT/etc/seedtunnel/seedbox.conf"
    restore_archive_make existing
    restore_record_steps existing
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    seedbox_check_web_ports() { :; }
    restore_refused_first existing "already exists on this server" || return 1
    # free account, but the web ports used by another program: refused too
    restore_archive_load webports
    printf 'SEEDBOX_USER=lancelot-test-free\n' >"$RESTORE_ROOT/etc/seedtunnel/seedbox.conf"
    restore_archive_make webports
    restore_record_steps webports
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    ss() { printf '%s\n' 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("apache2",pid=1,fd=4))'; }
    restore_refused_first webports "Ports 80/443 are already used by another program"
)

restore_refuses_missing_parts() (
    # the server has a VPN, the backup none
    restore_archive_load novpn
    rm -rf "$RESTORE_ROOT/etc/seedtunnel/vpn.conf" "$RESTORE_ROOT/etc/seedtunnel/vpn"
    printf 'FIREWALL_ENABLED=1\n' >"$RESTORE_ROOT/etc/seedtunnel/firewall.conf"
    restore_archive_make novpn
    restore_record_steps novpn
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    restore_refused_first novpn "This server has a VPN, the backup has none" || return 1
    # the server has a seedbox, the backup none
    restore_archive_load noseedbox
    restore_archive_make noseedbox
    restore_record_steps noseedbox
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    SEEDBOX_USER=neil
    restore_refused_first noseedbox "This server has a seedbox, the backup has none"
)

restore_keeps_firewall() (
    restore_archive_load keepfw
    restore_archive_make keepfw
    restore_record_steps keepfw
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    # the firewall of this server is on; the backup has none
    printf 'FIREWALL_ENABLED=1\n' >"$FIREWALL_CONF_FILE"
    restore_main "$WORK/keepfw.enc" >"$WORK/keepfw.out" 2>&1 || {
        cat "$WORK/keepfw.out"
        return 1
    }
    cat "$WORK/keepfw.out" "$RESTORE_STEPS"
    # still on, made again for the settings restored, and said
    firewall_enabled && grep -qx firewall "$RESTORE_STEPS" && grep -q "The firewall of this server stays on" "$WORK/keepfw.out"
)

restore_marks_until_finished() (
    restore_archive_load marker
    restore_archive_make marker
    restore_record_steps marker
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    printf 'SERVER=settings\n' >"$APP_STATE_DIR/server.conf"
    # while the settings are being put back, the marker says where the old ones went
    vpn_apply() { if [[ -e $RESTORE_MARKER ]]; then cat "$RESTORE_MARKER" >>"$RESTORE_STEPS"; fi; }
    restore_main "$WORK/marker.enc" >"$WORK/marker.out" 2>&1 || {
        cat "$WORK/marker.out"
        return 1
    }
    cat "$RESTORE_STEPS"
    grep -q "^$APP_STATE_DIR.before-restore-" "$RESTORE_STEPS" && [[ ! -e $RESTORE_MARKER ]]
)

doctor_reports_interrupted_restore() (
    load
    timedatectl() { echo yes; }
    RESTORE_MARKER="$WORK/interrupted.restore-unfinished"
    mkdir -p "$WORK/interrupted-before"
    printf '%s\n' "$WORK/interrupted-before" >"$RESTORE_MARKER"
    DOCTOR_ERRORS=0
    doctor_system >"$WORK/interrupted.out" 2>&1
    cat "$WORK/interrupted.out"
    # the way back, with the folder of the settings from before
    ((DOCTOR_ERRORS == 1)) && grep -q "A restore did not finish" "$WORK/interrupted.out" \
        && grep -qF "mv $WORK/interrupted-before $APP_STATE_DIR" "$WORK/interrupted.out" || return 1
    # nothing from before: restore again
    printf 'none\n' >"$RESTORE_MARKER"
    doctor_system >"$WORK/interrupted.out" 2>&1
    grep -q "Run it again" "$WORK/interrupted.out"
)

firewall_after_nftables_service() (
    load
    firewall_generate_unit | grep -qx 'After=nftables.service'
)

# Rules as « nft list » shows them
firewall_rules_sample() {
    cat <<EOF
table inet seedtunnel_fw {
	chain input {
		type filter hook input priority filter; policy $1;
		ct state established,related accept
		ct state invalid drop
		iifname "lo" accept
		meta l4proto { icmp, ipv6-icmp } accept
		ip6 saddr fe80::/10 udp dport 546 accept
		tcp dport $2 accept
		udp dport 51820 accept
		iifname "wg0" accept
		tcp dport { 80, 443 } accept
		meta l4proto { tcp, udp } th dport 60000 accept
		tcp dport 8080 accept
	}
}
EOF
}

firewall_rules_load() {
    load
    FIREWALL_CONF_FILE="$WORK/rules-fw.conf"
    printf 'FIREWALL_ENABLED=1\n' >"$FIREWALL_CONF_FILE"
    VPN_CLIENTS_DIR="$WORK/rules-clients"
    mkdir -p "$VPN_CLIENTS_DIR"
    printf 'CLIENT_NUMBER=2\n' >"$VPN_CLIENTS_DIR/laptop.env"
    VPN_PORT=51820
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    sshd() { printf 'port 22\n'; }
    unset SSH_CONNECTION
    RULES_POLICY=drop
    RULES_SSH=22
    nft() {
        case "$*" in
            "list table inet seedtunnel_fw") firewall_rules_sample "$RULES_POLICY" "$RULES_SSH" ;;
            "list table ip seedtunnel") printf '%s\n' 'table ip seedtunnel {' '	chain prerouting {' \
                '		iifname "eth0" meta l4proto { tcp, udp } th dport 60002 dnat to 10.8.0.3' '	}' '}' ;;
        esac
    }
}

firewall_rules_in_plain_words() (
    firewall_rules_load
    firewall_rules_show >"$WORK/rules.out" 2>&1
    cat "$WORK/rules.out"
    local expected
    for expected in "Replies to the connections already open" "Ping and ICMP messages" "SSH / SFTP: port 22/tcp" \
        "VPN WireGuard: port 51820/udp" "Everything coming from the VPN clients" "Web site: ports 80, 443/tcp" \
        "BitTorrent: port 60000 (TCP and UDP)" "Everything else is refused." \
        "port 60002 (TCP and UDP) → laptop (10.8.0.3)"; do
        grep -qF "$expected" "$WORK/rules.out" || {
            echo "missing: $expected"
            return 1
        }
    done
    # a rule the settings did not ask for is pointed out
    grep -qF "Other port open: 8080/tcp" "$WORK/rules.out"
)

firewall_rules_differences_said() (
    firewall_rules_load
    # the loaded rules accept everything, and no longer have the SSH port
    RULES_POLICY=accept
    RULES_SSH=2222
    firewall_rules_show >"$WORK/rules-diff.out" 2>&1
    cat "$WORK/rules-diff.out"
    grep -q "Everything else is accepted" "$WORK/rules-diff.out" \
        && grep -q "Missing from the rules loaded, although the settings need it: SSH 22/tcp" "$WORK/rules-diff.out"
)

firewall_rules_when_off() (
    firewall_rules_load
    printf 'FIREWALL_ENABLED=0\n' >"$FIREWALL_CONF_FILE"
    firewall_rules_show >"$WORK/rules-off.out" 2>&1
    cat "$WORK/rules-off.out"
    # the ports of the clients can still be reached
    grep -q "Firewall off: nothing is refused" "$WORK/rules-off.out" && grep -qF "port 60002" "$WORK/rules-off.out"
)

# A log with what the report must not carry, and what it must keep
report_load() {
    load
    SEEDBOX_DOMAIN=seedbox.example.org
    SEEDBOX_USER=neil
    VPN_PUBLIC_ADDRESS=vpn.example.org
    VPN_CLIENTS_DIR="$WORK/report-clients"
    rm -rf "$VPN_CLIENTS_DIR"
    mkdir -p "$VPN_CLIENTS_DIR"
    printf 'CLIENT_NUMBER=2\n' >"$VPN_CLIENTS_DIR/laptop.env"
    printf 'CLIENT_NUMBER=3\n' >"$VPN_CLIENTS_DIR/phone.env"
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    hostname() { if [[ ${1-} == -f ]]; then echo vps-1234.example.net; else echo vps-1234; fi; }
    ip() { printf '%s\n' '2: eth0    inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0'; }
    cat >"$WORK/report.txt" <<'EOF'
Looking for the public IP address… 203.0.113.10
✔ « seedbox.example.org » points to this server (203.0.113.10)
✔ Clients: 2, 1 connected right now (VPN at vpn.example.org:51820)
=== 2026-11-06 19:16:38 · download link for laptop.conf
=== 2026-11-06 19:17:01 · download link for tablet.conf
$ rm -f /etc/seedtunnel/vpn/clients/watch.env /etc/seedtunnel/vpn/clients/watch.conf
$ usermod -aG debian-transmission neil
peer phone 10.8.0.4 port 60003, laptop 10.8.0.3 port 60002 (from 192.168.1.5)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBx7Lk7v9h2m neil@desktop
banned 198.51.100.7 and 2001:db8::10, server vps-1234 (vps-1234.example.net)
/var/backups/seedtunnel/seedtunnel-vps-1234-20261106-191708-auto.tar.gz.enc
EOF
}

report_replaces_private_values() (
    report_load
    report_anonymize "$WORK/report.txt"
    cat "$WORK/report.txt"
    local private kept
    for private in seedbox.example.org vpn.example.org vps-1234 203.0.113.10 198.51.100.7 2001:db8::10 \
        neil laptop phone tablet watch desktop AAAAC3NzaC1lZDI1NTE5; do
        if grep -qw -- "$private" "$WORK/report.txt"; then
            echo "still in the report: $private"
            return 1
        fi
    done
    for kept in "<domain>" "<server>" "<server-ip>" "<ip>" "<sftp-user>" "<client-2>" "<client-3>" "<former-client>" \
        "<ssh-key>" 10.8.0.3 192.168.1.5 51820 60002 19:16:38 debian-transmission "seedtunnel-<server>-20261106"; do
        grep -qF -- "$kept" "$WORK/report.txt" || {
            echo "missing from the report: $kept"
            return 1
        }
    done
)

report_saved_without_seedbox() (
    report_load
    seedbox_installed() { return 1; }
    mkdir -p "$WORK/report-home"
    SUDO_USER=$(id -un)
    getent() { printf '%s:x:0:0::%s:/bin/sh\n' "$SUDO_USER" "$WORK/report-home"; }
    report_generate() { cp "$WORK/report.txt" "$1"; }
    rm -f "$WORK"/report-home/*
    report_send >"$WORK/report-send.out" 2>&1 || {
        cat "$WORK/report-send.out"
        return 1
    }
    cat "$WORK/report-send.out"
    local saved
    saved=$(find "$WORK/report-home" -name 'seedtunnel-report-*.txt')
    [[ -n $saved && $(stat -c %a "$saved") == 600 ]] && grep -q "Report saved: $saved" "$WORK/report-send.out"
)

report_longest_first_common_words_kept() (
    report_load
    # the account neil, the client neil-laptop, a client named like a word
    printf 'CLIENT_NUMBER=4\n' >"$VPN_CLIENTS_DIR/neil-laptop.env"
    printf 'CLIENT_NUMBER=5\n' >"$VPN_CLIENTS_DIR/vpn.env"
    # the server is also 10.8.0.1 in its VPN: an address of every server
    ip() { printf '%s\n' '2: eth0    inet 203.0.113.10/24 scope global eth0' '3: wg0    inet 10.8.0.1/24 scope global wg0'; }
    printf '%s\n' 'peer neil-laptop of neil, the vpn listens on 10.8.0.1 and 203.0.113.10' >"$WORK/report.txt"
    report_anonymize "$WORK/report.txt"
    cat "$WORK/report.txt"
    [[ $(<"$WORK/report.txt") == 'peer <client-4> of <sftp-user>, the vpn listens on 10.8.0.1 and <server-ip>' ]]
)

restore_failure_says_marker() (
    load
    RESTORE_PREVIOUS="$WORK/failure-before"
    RESTORE_MARKER="$WORK/failure.restore-unfinished"
    restore_unfinished 2>"$WORK/failure.out"
    cat "$WORK/failure.out"
    # the way back also removes the marker, or « doctor » would say it forever
    grep -qF "mv $WORK/failure-before $APP_STATE_DIR && rm -f $RESTORE_MARKER && seedtunnel apply" "$WORK/failure.out"
)

# --- 2.0.0 ---------------------------------------------------------------------

# Seen in a real report: « inotify-tools 4.23.9.0-2+b1 » became « <ip>-2+b1 »
report_keeps_version_numbers() (
    report_load
    cat >"$WORK/report.txt" <<'EOF'
Unpacking libinotifytools0:amd64 (4.23.9.0-2+b1) ...
amd64 libinotifytools0 amd64 4.23.9.0-2+b1 [23.1 kB] and version 1.2.3.4.5
banned 198.51.100.7. Then 198.51.100.7, (198.51.100.7) and 198.51.100.7:51820
EOF
    report_anonymize "$WORK/report.txt"
    cat "$WORK/report.txt"
    (($(grep -c '4\.23\.9\.0-2+b1' "$WORK/report.txt") == 2)) && grep -q '1\.2\.3\.4\.5' "$WORK/report.txt" \
        && ! grep -q '198\.51\.100\.7' "$WORK/report.txt" && (($(grep -o '<ip>' "$WORK/report.txt" | wc -l) == 4))
)

# Seen in a real log: « Error: No such file or directory … delete table » after
# a VPN was removed (stopping WireGuard had removed the table already)
nft_tables_deleted_only_when_there() (
    load
    : >"$WORK/nft-calls"
    NFT_TABLE_THERE=0
    nft() {
        echo "nft $*" >>"$WORK/nft-calls"
        if [[ $1 == list ]]; then ((NFT_TABLE_THERE)); fi
    }
    nft_delete_table ip seedtunnel
    ! grep -q "nft delete" "$WORK/nft-calls" || return 1
    NFT_TABLE_THERE=1
    nft_delete_table ip seedtunnel
    grep -qx "nft delete table ip seedtunnel" "$WORK/nft-calls" || return 1
    # used where a table may be gone already
    declare -f vpn_uninstall | grep -q 'nft_delete_table ip seedtunnel' \
        && declare -f firewall_disable | grep -q 'nft_delete_table inet "$FIREWALL_TABLE"'
)

# --- 2.0.0: interface (lib/ui.sh, tools/preview.sh) ----------------------------

# Lengths in characters, whatever the locale: printf '%-10s' counts bytes, and
# « é », « ● » or « ─ » shifted the columns
ui_counts_characters() (
    local locale out
    cat >"$WORK/lengths.sh" <<'EOF'
APP_DIR=$1
. "$APP_DIR/lib/common.sh"
. "$APP_DIR/lib/i18n.sh"
. "$APP_DIR/lib/ui.sh"
ui_len "été ● ─"
printf '%s|' "$UI_LEN"
ui_len $'\e[0mx\e[1;38;5;141mé\e[0m'
printf '%s|' "$UI_LEN"
ui_cut "Sauvegardé" 5
printf '%s|' "$UI_CUT"
ui_cut "à jour" 6
printf '%s|' "$UI_CUT"
ui_pad "été" 5
printf '%s|' "$UI_PAD"
ui_take "éèà" 2
printf '%s/%s' "$UI_TAKE" "$UI_REST"
EOF
    for locale in C C.UTF-8; do
        out=$(LC_ALL=$locale bash "$WORK/lengths.sh" "$ROOT" 2>&1)
        [[ $out == "7|2|Sauv…|à jour|été  |éè/à" ]] || {
            echo "LC_ALL=$locale: $out"
            return 1
        }
    done
)

# A long word (a path) is split, never shortened; the text stays whole
ui_wraps_without_losing_text() (
    load
    local path=/etc/seedtunnel/vpn/clients/phone2.conf joined="" line
    ui_wrap "File: $path, to keep" 12
    for line in "${UI_LINES[@]}"; do
        ui_len "$line"
        ((UI_LEN <= 12)) || return 1
        joined+=$line
    done
    [[ ${joined// /} == "File:$path,tokeep" ]] || {
        printf '%s\n' "${UI_LINES[@]}"
        return 1
    }
)

colors_follow_terminal_and_no_color() (
    load
    stdout_is_terminal() { return 0; }
    TERM=xterm-256color
    unset NO_COLOR COLORTERM
    colors_init
    [[ $C_BRAND == *"38;5;207"* && $C_GREY == *"38;5;245"* && $UI_COLORS == 256 ]] || return 1
    TERM=xterm
    colors_init
    [[ $C_BRAND == $'\e[1;35m' && $UI_COLORS == 8 ]] || return 1
    COLORTERM=truecolor
    colors_init
    [[ $UI_COLORS == 256 ]] || return 1
    # NO_COLOR (https://no-color.org): set and not empty → no color at all
    NO_COLOR=1
    colors_init
    [[ -z $C_BRAND$C_GREEN$C_RESET$C_BADGE$C_GREY && $UI_COLORS == 0 ]] || return 1
    NO_COLOR=""
    colors_init
    [[ -n $C_BRAND ]] || return 1
    TERM=dumb
    colors_init
    [[ -z $C_BRAND ]] || return 1
    stdout_is_terminal() { return 1; }
    TERM=xterm-256color
    colors_init
    [[ -z $C_BRAND ]] || return 1
    ui_key q
    [[ $UI_KEY == "[Q]" ]] || return 1
    # with colors: the same [Q], the key in pink, no background behind it
    # (Neil, 7 Nov.: the pink background under the numbers was too much); the
    # version keeps its pink background
    colors_init on
    ui_key q
    [[ $UI_KEY == "${C_GREY}[$C_RESET${C_BRAND}Q$C_RESET$C_GREY]$C_RESET" ]] || return 1
    UI_COLUMNS=80
    ui_width
    local header
    header=$(ui_header)
    [[ $header == *"$C_BADGE v$APP_VERSION $C_RESET"* ]] || return 1
    # keys of the bottom line (B, R, Q): white on pink, like the version
    ui_footer r Refresh q Quit >/dev/null
    [[ $UI_PROMPT == "  $C_BADGE R $C_RESET Refresh    $C_BADGE Q $C_RESET Quit "* ]] || return 1
    colors_init off
    ui_footer r Refresh q Quit >/dev/null
    [[ $UI_PROMPT == "  [R] Refresh    [Q] Quit "* ]]
)

# No line wider than the screen, in English and in French, with and without
# colors, from 20 columns (a phone) to 200
preview_fits_every_width() (
    load
    local columns language colors width line out
    for columns in 20 30 40 60 70 71 79 80 81 120 200; do
        width=$((columns - 1))
        if ((width > 79)); then width=79; fi
        if ((width < 20)); then width=20; fi
        for language in en fr; do
            for colors in --color --no-color; do
                out=$(TERM=xterm-256color "$ROOT/tools/preview.sh" --all "--$language" "$colors" --columns "$columns" 2>&1) || {
                    printf '%s\n' "$out" | tail -n 5
                    return 1
                }
                if [[ $colors == --no-color && $out == *$'\e'* ]]; then
                    echo "color code with --no-color ($language, $columns columns)"
                    return 1
                fi
                while IFS= read -r line; do
                    ui_len "$line"
                    if ((UI_LEN > width)); then
                        echo "$columns columns, $language $colors: $UI_LEN > $width: $UI_STRIP"
                        return 1
                    fi
                done <<<"$out"
            done
        done
    done
)

# Same screens whether the locale counts characters or bytes (LANG not set)
preview_same_in_every_locale() (
    local utf8 bytes
    utf8=$(LC_ALL=C.UTF-8 "$ROOT/tools/preview.sh" --all --fr --color --columns 80 2>&1) || return 1
    bytes=$(LC_ALL=C "$ROOT/tools/preview.sh" --all --fr --color --columns 80 2>&1) || return 1
    [[ $utf8 == "$bytes" ]] || {
        diff <(printf '%s\n' "$utf8") <(printf '%s\n' "$bytes")
        return 1
    }
)

# Blocks from 80 columns (PuTTY), list below; two columns of menu from 71
preview_layout_follows_width() (
    local out
    out=$("$ROOT/tools/preview.sh" --all --fr --no-color --columns 80) || return 1
    out=${out%%=== vpn*}
    grep -q '┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐' <<<"$out" || return 1
    grep -q '\[1\] .*\[5\] ' <<<"$out" || return 1
    out=$("$ROOT/tools/preview.sh" --all --fr --no-color --columns 79) || return 1
    out=${out%%=== vpn*}
    ! grep -q '┌─────────────┐' <<<"$out" || return 1
    grep -q '^  Sauvegarde  ● à jour  *il y a 3 jours$' <<<"$out" || return 1
    grep -q '\[1\] .*\[5\] ' <<<"$out" || return 1
    out=$("$ROOT/tools/preview.sh" --all --fr --no-color --columns 70) || return 1
    out=${out%%=== vpn*}
    ! grep -q '\[1\] .*\[5\] ' <<<"$out" || return 1
    grep -q '^  \[5\] Sauvegarde / restauration$' <<<"$out"
)

# Columns of a table stay aligned with accents and colors
ui_table_aligned_with_accents() (
    load
    local out
    out=$(ui_table $'NOM\tÉTAT\tFIN' $'été\t'"$C_GREEN"$'● en marche'"$C_RESET"$'\tx' $'a\tarrêté\ty')
    [[ $out == "  NOM  ÉTAT         FIN"$'\n'"  ─────────────────────"$'\n'"  été  ● en marche  x"$'\n'"  a    arrêté       y" ]] || {
        printf '%s\n' "$out"
        return 1
    }
)

# The answer of a menu without its spaces; Q after an action; no question
# outside the menus
ui_choice_and_pause_answers() (
    load
    local choice
    INTERACTIVE=1
    ui_menu_ask choice back <<<"  2 " >/dev/null 2>&1
    [[ $choice == 2 ]] || return 1
    ui_pause <<<"" >/dev/null 2>&1 || return 1
    ! ui_pause <<<" Q" >/dev/null 2>&1 || return 1
    INTERACTIVE=0
    ! (ui_menu_ask choice <<<"1") >/dev/null 2>&1 || return 1
    ui_pause </dev/null
)

# --- 2.0.0: menus (lib/menu.sh, ui_action) ----------------------------------------

# A server with everything in order, for the menus run in a process of their
# own (strict): stdin gives the answers, the real « read » of the menus
fake_server() {
    error_trap_on
    INTERACTIVE=1
    UI_COLUMNS=${COLUMNS_TEST:-80}
    i18n_load "${LANGUAGE_TEST:-en}"
    clear() { :; }
    vpn_load() { :; }
    seedbox_load() { :; }
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    systemctl() { [[ $1 != is-failed ]]; }
    vpn_connected_count() { echo 2; }
    vpn_count_clients() { echo 3; }
    diskguard_stopped() { return 1; }
    firewall_enabled() { return 0; }
    nft() { printf 'table inet seedtunnel {\n chain input { type filter hook input priority 0; policy drop; }\n}\n'; }
    firewall_rules_missing() { :; }
    df() {
        if [[ $* == *target* ]]; then printf 'Mounted on\n/\n'; else printf 'Size Avail\n%s %s\n' $((100 * 1024 ** 3)) $((40 * 1024 ** 3)); fi
    }
    backup_latest() { echo "$WORK/backup.enc"; }
    touch -d '3 days ago' "$WORK/backup.enc"
    backup_auto_enabled() { return 0; }
    BACKUP_PASSPHRASE_FILE="$WORK/passphrase"
    echo x >"$BACKUP_PASSPHRASE_FILE"
    restore_interrupted() { return 1; }
    VPN_PUBLIC_ADDRESS=203.0.113.10
    VPN_PORT=51820
    VPN_INTERFACE=wg0
    SEEDBOX_DOMAIN=seed.example.net
    SEEDBOX_DATA_DIR=$WORK
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_LETSENCRYPT_SERVER=production
    SEEDBOX_USER=neil
    SEEDBOX_SFTP_PASSWORD=yes
    UI_SERVER=vps-test
    UI_SYSTEM="Debian 13"
}

menus() { strict "$(declare -f fake_server); fake_server; $1"; }

# B or an empty answer goes back, R refreshes, a wrong answer is ignored, Q
# leaves seedtunnel from a submenu (« See you soon! », status 0)
menus_keys_b_r_q() (
    local out
    out=$(printf '1\nr\nb\n1\n\nzz\n1\nq\n' | menus 'main_menu; echo "after the menu"' 2>&1) || {
        echo "status $?"
        return 1
    }
    [[ $out == *"See you soon!"* && $out != *"after the menu"* ]] || return 1
    # home screen 1 + VPN 1 + refresh + home 2 + VPN 2 + home 3 (zz) + home 4 + VPN 3
    (($(grep -c "seedtunnel › VPN" <<<"$out") == 4)) || {
        grep -c "seedtunnel › VPN" <<<"$out"
        return 1
    }
)

# An action that fails comes back to the menu after « Enter » (it no longer
# leaves seedtunnel); « set -e » works inside the action; Q after it quits
action_error_comes_back_to_menu() (
    local out
    out=$(printf '\n\n' | menus '
        broken() { false; echo "went on after an error"; }
        stopped() { die "Stopped by %s" "the test"; }
        ui_action broken
        echo "back 1"
        ui_action stopped
        echo "back 2"' 2>&1) || return 1
    [[ $out == *"Unexpected error"* && $out != *"went on after an error"* && $out == *"back 1"* ]] || {
        echo "$out"
        return 1
    }
    [[ $out == *"Stopped by the test"* && $out == *"back 2"* ]] || return 1
    # Q at the pause after the error: seedtunnel stops there
    out=$(printf 'q\n' | menus 'broken() { false; }; ui_action broken; echo "not left"' 2>&1) || return 1
    [[ $out == *"See you soon!"* && $out != *"not left"* ]]
)

# Q inside an action of a submenu: passed on up to the main menu
quit_from_an_action() (
    local out
    out=$(printf '1\n5\nq\n' | menus 'vpn_status_table() { echo "TABLE"; }; main_menu; echo "after the menu"' 2>&1) || return 1
    [[ $out == *TABLE* && $out == *"See you soon!"* && $out != *"after the menu"* ]]
)

# Each state of the home screen, with its color
home_states() (
    load
    local -a levels
    systemctl() { return 1; }
    vpn_installed() { return 1; }
    seedbox_installed() { return 1; }
    home_vpn
    home_seedbox
    [[ ${UI_STATUS_LEVELS[*]} == "off off" && ${UI_STATUS_STATES[*]} == "missing absent" ]] || return 1
    ui_status_reset
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    vpn_connected_count() { echo 1; }
    vpn_count_clients() { echo 2; }
    diskguard_stopped() { return 1; }
    home_vpn
    home_seedbox
    systemctl() { [[ $* != *nginx* ]]; }
    home_seedbox
    systemctl() { [[ $* != *transmission* ]]; }
    home_seedbox
    diskguard_stopped() { return 0; }
    home_seedbox
    systemctl() { return 0; }
    diskguard_stopped() { return 1; }
    home_vpn
    home_seedbox
    [[ ${UI_STATUS_LEVELS[*]} == "bad bad bad bad bad ok ok" ]] || {
        echo "${UI_STATUS_LEVELS[*]} / ${UI_STATUS_STATES[*]}"
        return 1
    }
    [[ ${UI_STATUS_STATES[*]} == "stopped halted problem halted halted running running" && ${UI_STATUS_DETAILS[5]} == "1 of 2 clients connected" ]] || return 1
    # firewall: off, on, rules missing, rules that refuse nothing by default
    ui_status_reset
    firewall_enabled() { return 1; }
    home_firewall
    firewall_enabled() { return 0; }
    firewall_rules_missing() { :; }
    nft() { printf 'type filter hook input priority 0; policy drop;\n'; }
    home_firewall
    firewall_rules_missing() { echo "SSH 22/tcp" >&2; }
    home_firewall
    firewall_rules_missing() { :; }
    nft() { printf 'type filter hook input priority 0; policy accept;\n'; }
    home_firewall
    nft() { :; }
    home_firewall
    [[ ${UI_STATUS_LEVELS[*]} == "warn ok bad bad bad" && ${UI_STATUS_STATES[*]} == "off on problem problem problem" ]] || {
        echo "${UI_STATUS_LEVELS[*]} / ${UI_STATUS_STATES[*]}"
        return 1
    }
    # disk: pink while there is room, then yellow, then red; used part in %
    ui_status_reset
    seedbox_installed() { return 1; }
    DF_FREE=$((40 * 1024 ** 3))
    df() { printf 'Size Avail\n%s %s\n' $((100 * 1024 ** 3)) "$DF_FREE"; }
    home_disk
    DF_FREE=$((4 * 1024 ** 3))
    home_disk
    DF_FREE=$((1 * 1024 ** 3))
    home_disk
    [[ ${UI_STATUS_LEVELS[*]} == "info warn bad" && ${UI_STATUS_STATES[0]} == "60%" && ${UI_STATUS_DETAILS[0]} == "40GB free" ]] || {
        echo "${UI_STATUS_LEVELS[*]} / ${UI_STATUS_STATES[*]} / ${UI_STATUS_DETAILS[*]}"
        return 1
    }
    # backup: weekly failed, without passphrase, none, recent, old
    ui_status_reset
    seedbox_installed() { return 0; }
    BACKUP_PASSPHRASE_FILE="$WORK/home-passphrase"
    echo x >"$BACKUP_PASSPHRASE_FILE"
    backup_auto_enabled() { return 0; }
    backup_latest() { return 1; }
    systemctl() { [[ $1 == is-failed ]]; }
    home_backup
    systemctl() { return 1; }
    rm -f "$BACKUP_PASSPHRASE_FILE"
    home_backup
    backup_auto_enabled() { return 1; }
    home_backup
    touch -d '2 days ago' "$WORK/home-backup.enc"
    backup_latest() { echo "$WORK/home-backup.enc"; }
    home_backup
    touch -d '9 days ago' "$WORK/home-backup.enc"
    home_backup
    [[ ${UI_STATUS_LEVELS[*]} == "bad bad warn ok warn" && ${UI_STATUS_STATES[*]} == "failed failed none yet recent old" ]] || {
        echo "${UI_STATUS_LEVELS[*]} / ${UI_STATUS_STATES[*]}"
        return 1
    }
    [[ ${UI_STATUS_DETAILS[3]} == "last backup 2 days ago" && ${UI_STATUS_SHORT[3]} == "2 days ago" ]]
)

# The words of the blocks fit in them (9 characters), in English and in French
home_state_words_fit_blocks() (
    load
    local language word
    for language in en fr; do
        i18n_load "$language"
        for word in missing running stopped absent halted problem on off failed 'none yet' recent old; do
            ui_len "$(t "$word")"
            if ((UI_LEN > 9)); then
                echo "$language: « $(t "$word") » is $UI_LEN characters long"
                return 1
            fi
        done
    done
)

# The real screens of the menus fit the screen too (EN/FR, 40 and 80 columns)
menus_fit_the_screen() (
    local language columns out line width
    load
    for language in en fr; do
        for columns in 40 80; do
            width=$((columns - 1))
            out=$(printf '1\nb\n2\nb\n3\nb\n5\nb\nl\nb\nq\n' | COLUMNS_TEST=$columns LANGUAGE_TEST=$language menus '
                firewall_status() { :; }
                backup_auto_status() { :; }
                main_menu' 2>&1) || {
                echo "$out" | tail -n 5
                return 1
            }
            while IFS= read -r line; do
                ui_len "$line"
                if ((UI_LEN > width)); then
                    echo "$language, $columns columns: $UI_LEN > $width: $line"
                    return 1
                fi
            done <<<"$out"
        done
    done
)

# --- 2.1.0 -------------------------------------------------------------------------

# The log is cut every month (it used to grow without end), from the
# installation and from « apply » (so after an update too)
log_rotation_rule() (
    load
    LOGROTATE_FILE="$WORK/logrotate-seedtunnel"
    apt_install() { echo "apt $*" >>"$WORK/logrotate-calls"; }
    # the tests do not run as root (root:root cannot be given)
    chown() { :; }
    rm -f "$LOGROTATE_FILE" "$WORK/logrotate-calls"
    log_rotation_apply
    grep -qx "apt logrotate" "$WORK/logrotate-calls" || return 1
    grep -q "^$APP_LOG {" "$LOGROTATE_FILE" || return 1
    local word
    for word in monthly 'rotate 6' compress 'create 0600 root root' missingok; do
        grep -q "^    $word\$" "$LOGROTATE_FILE" || {
            echo "missing: $word"
            return 1
        }
    done
    [[ $(stat -c %a "$LOGROTATE_FILE") == 644 ]] || return 1
    declare -f base_setup | grep -q log_rotation_apply && declare -f apply_main | grep -q log_rotation_apply
)

# Stopping a service writes its own title in the log: its « Removed … » line no
# longer looks like part of the step before
log_titles_before_service_stops() (
    load
    local out
    : >"$APP_LOG"
    systemctl() { echo "Removed '/etc/systemd/system/x.wants/$3'."; }
    log_run 'Stopping the firewall' systemctl disable --now seedtunnel-firewall.service
    out=$(<"$APP_LOG")
    [[ $out == *" · Stopping the firewall"$'\n''$ systemctl disable --now seedtunnel-firewall.service'$'\n'"Removed '"* ]] || {
        echo "$out"
        return 1
    }
    # never a failure
    systemctl() { return 5; }
    log_run 'Stopping the VPN' systemctl disable --now wg-quick@wg0 || return 1
    # no service stopped into the log without a title any more
    out=$(grep -n 'disable --now .*>>"$APP_LOG"' "$ROOT"/lib/*.sh || true)
    [[ -z $out ]] || {
        echo "$out"
        return 1
    }
)

# An installed version (records « NAME » when it applies, ends with STATUS)
# in FOLDER, with the code of version VERSION
fake_version_make() {
    local folder=$1 version=$2 name=$3 status=${4:-0}
    mkdir -p "$folder/lib" "$folder/lang"
    printf '#!/bin/sh\necho %s >>"%s"\nexit %s\n' "$name" "$WORK/app/applied" "$status" >"$folder/seedtunnel.sh"
    chmod +x "$folder/seedtunnel.sh"
    printf 'APP_VERSION="%s"\n' "$version" >"$folder/lib/common.sh"
    echo 'x=1' >"$folder/lang/en.sh"
}

# The version replaced by an update is kept (one only)
update_keeps_previous_version() (
    load
    update_versions_make 0
    mkdir -p "$APP_DIR.old"
    echo older >"$APP_DIR.old/marker"
    (update_switch "$WORK/app/new" 9.9.9) &>"$WORK/update.out" || {
        cat "$WORK/update.out"
        return 1
    }
    grep -q "echo new" "$APP_DIR/seedtunnel.sh" && grep -q "echo old" "$APP_DIR.old/seedtunnel.sh" \
        && [[ ! -e $APP_DIR.old/marker && ! -e $APP_DIR.previous ]]
)

# « seedtunnel update back »: the version kept comes back and applies the
# settings; the newer one goes (« seedtunnel update » downloads it again)
update_back_puts_previous_back() (
    load
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app"
    APP_VERSION=2.1.0
    fake_version_make "$APP_DIR" 2.1.0 new
    fake_version_make "$APP_DIR.old" 2.0.0 old
    OPT_YES=1
    [[ $(update_old_version) == 2.0.0 ]] || return 1
    (update_back) &>"$WORK/back.out" || {
        cat "$WORK/back.out"
        return 1
    }
    grep -q 'APP_VERSION="2.0.0"' "$APP_DIR/lib/common.sh" && [[ $(<"$WORK/app/applied") == old ]] \
        && [[ ! -e $APP_DIR.old && ! -e $APP_DIR.previous ]]
)

# The older version cannot apply the settings: the newer one comes back,
# applies them again, and the older one stays kept
update_back_failure_puts_newer_back() (
    load
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app"
    APP_VERSION=2.1.0
    fake_version_make "$APP_DIR" 2.1.0 new
    fake_version_make "$APP_DIR.old" 2.0.0 old 7
    OPT_YES=1
    if (update_back) &>"$WORK/back.out"; then return 1; fi
    grep -q "Going back cancelled" "$WORK/back.out" || {
        cat "$WORK/back.out"
        return 1
    }
    grep -q 'APP_VERSION="2.1.0"' "$APP_DIR/lib/common.sh" && grep -q 'APP_VERSION="2.0.0"' "$APP_DIR.old/lib/common.sh" \
        && [[ $(tr '\n' ' ' <"$WORK/app/applied") == "old new " && ! -e $APP_DIR.previous ]]
)

# Nothing to go back to: no version kept, or not an older one, or a git
# installation; « no » changes nothing
update_back_refused_when_nothing_to_go_back_to() (
    load
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app"
    APP_VERSION=2.1.0
    fake_version_make "$APP_DIR" 2.1.0 new
    if (update_back) &>"$WORK/back.out"; then return 1; fi
    grep -q "No previous version kept" "$WORK/back.out" || return 1
    fake_version_make "$APP_DIR.old" 2.1.0 same
    [[ -z $(update_old_version) ]] || return 1
    if (update_back) &>"$WORK/back.out"; then return 1; fi
    fake_version_make "$APP_DIR.old" 2.0.0 old
    confirm() { return 1; }
    (update_back) &>"$WORK/back.out" || return 1
    [[ ! -e $WORK/app/applied ]] && grep -q 'APP_VERSION="2.1.0"' "$APP_DIR/lib/common.sh" || return 1
    mkdir "$APP_DIR/.git"
    if (update_back) &>"$WORK/back.out"; then return 1; fi
    grep -q "git" "$WORK/back.out" || return 1
    # the command: « update » or « update back », nothing else
    if (update_cli wrong) &>"$WORK/back.out"; then return 1; fi
    grep -q "Usage: seedtunnel update \[back\]" "$WORK/back.out"
)

# Update made by 2.0 (which deletes the version it replaced once « apply »
# worked): the « apply » of the new version keeps a copy of the older one
apply_saves_previous_for_back() (
    load
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app"
    APP_VERSION=2.1.0
    fake_version_make "$APP_DIR" 2.1.0 new
    fake_version_make "$APP_DIR.previous" 2.0.0 old
    update_save_previous
    [[ -e $APP_DIR.previous ]] && grep -q 'APP_VERSION="2.0.0"' "$APP_DIR.old/lib/common.sh" || return 1
    # not a version newer or the same
    rm -rf "$APP_DIR.old"
    fake_version_make "$APP_DIR.previous" 2.1.0 same
    update_save_previous
    [[ ! -e $APP_DIR.old ]] && declare -f apply_main | grep -q update_save_previous
)

# The update screen of the menu: a choice when a version is kept; otherwise
# the update straight away, as in 2.0
update_menu_offers_way_back() (
    back_load
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app"
    APP_VERSION=2.1.0
    fake_version_make "$APP_DIR" 2.1.0 new
    update_main() { echo "update" >>"$WORK/menu-calls"; }
    update_back() { echo "back" >>"$WORK/menu-calls"; }
    : >"$WORK/menu-calls"
    update_menu >/dev/null 2>&1 || return 1
    [[ $(<"$WORK/menu-calls") == update ]] || return 1
    fake_version_make "$APP_DIR.old" 2.0.0 old
    : >"$WORK/menu-calls"
    answers "2" "1" "b"
    update_menu >/dev/null 2>&1 || return 1
    [[ $(tr '\n' ' ' <"$WORK/menu-calls") == "back update " ]]
)

# BitTorrent port seen from the Internet: open, closed (warning, with the
# firewall of the provider), not tested (no warning); not without Transmission
doctor_tests_torrent_port() (
    load
    local out
    DOCTOR_WARNINGS=0
    systemctl() { return 0; }
    curl() { [[ $* == *"-4"* && $* == *"portcheck.transmissionbt.com/$TORRENT_PORT"* ]] && echo 1; }
    out=$(doctor_torrent_port)
    [[ $out == *"BitTorrent port $TORRENT_PORT open from the Internet"* ]] || return 1
    curl() { echo 0; }
    doctor_torrent_port >"$WORK/port.out"
    grep -q "closed from the Internet.*Edge Network Firewall" "$WORK/port.out" && ((DOCTOR_WARNINGS == 1)) || return 1
    curl() { return 28; }
    doctor_torrent_port >"$WORK/port.out"
    grep -q "not tested" "$WORK/port.out" && ((DOCTOR_WARNINGS == 1)) || return 1
    systemctl() { return 3; }
    curl() { echo "curl called" >"$WORK/port.out"; }
    : >"$WORK/port.out"
    doctor_torrent_port
    [[ ! -s $WORK/port.out ]] && declare -f doctor_seedbox | grep -q doctor_torrent_port
)

# SFTP password: a warning of the diagnostics only once there is an SSH key;
# in yellow in the menus while it is allowed
sftp_password_warning() (
    load
    local out
    DOCTOR_WARNINGS=0
    SEEDBOX_SFTP_PASSWORD=yes
    sftp_keys_count() { echo 0; }
    out=$(doctor_sftp_password)
    [[ $out == *"password allowed"* ]] && ((DOCTOR_WARNINGS == 0)) || return 1
    sftp_keys_count() { echo 1; }
    doctor_sftp_password >"$WORK/sftp.out"
    grep -q "sftp-password off" "$WORK/sftp.out" && ((DOCTOR_WARNINGS == 1)) || return 1
    SEEDBOX_SFTP_PASSWORD=no
    out=$(doctor_sftp_password)
    [[ $out == *"keys only"* ]] && ((DOCTOR_WARNINGS == 1)) || return 1
    colors_init on
    [[ $(sftp_password_state) == "$C_GREEN"* ]] || return 1
    SEEDBOX_SFTP_PASSWORD=yes
    [[ $(sftp_password_state) == "$C_YELLOW"* ]] && declare -f doctor_seedbox | grep -q doctor_sftp_password
)

printf '\033[1m=== Unit tests\033[0m\n'

# --- 2.1.1: the clients connect, but another program blocks their traffic --------

# Rules as Docker leaves them (iptables-nft): forward hook refused by default,
# nothing for the VPN in DOCKER-USER. Read on a real server, where the clients
# connected but had no Internet: « doctor » said nothing.
docker_ruleset() {
    printf '%s\n' 'table inet seedtunnel_fw {' '	chain input {' '		type filter hook input priority filter; policy drop;' '		udp dport 51820 accept' '	}' '}' \
        'table ip filter {' '	chain DOCKER-FORWARD {' '		iifname "docker0" counter packets 0 bytes 0 accept' '	}' \
        '	chain FORWARD {' '		type filter hook forward priority filter; policy drop;' \
        '		counter packets 462 bytes 50273 jump DOCKER-USER' '		counter packets 462 bytes 50273 jump DOCKER-FORWARD' '	}' \
        '	chain DOCKER-USER {'
    if [[ ${DOCKER_USER_RULES-} == yes ]]; then
        printf '%s\n' '		iifname "ens3" oifname "wg0" xt match "conntrack" counter packets 0 bytes 0 accept' \
            '		iifname "wg0" oifname "ens3" counter packets 0 bytes 0 accept'
    fi
    printf '%s\n' '	}' '}' 'table ip seedtunnel {' '	chain postrouting {' '		type nat hook postrouting priority srcnat; policy accept;' \
        '		ip saddr 10.8.0.0/24 oifname "ens3" masquerade' '	}' '}'
}

doctor_sees_vpn_traffic_blocked() (
    load
    colors_init off
    default_interface() { echo ens3; }
    nft() { [[ $* == "list ruleset" ]] && docker_ruleset; }
    DOCKER_DAEMON_CONFIG="$WORK/daemon.json"
    rm -f "$DOCKER_DAEMON_CONFIG"
    # blocked: red, with what to type right now and for good
    DOCTOR_ERRORS=0 DOCTOR_WARNINGS=0
    doctor_vpn_forward >"$WORK/fwd.out"
    cat "$WORK/fwd.out"
    ((DOCTOR_ERRORS == 1)) && grep -q "Docker blocks the traffic of the clients" "$WORK/fwd.out" \
        && grep -qF 'iptables -I DOCKER-USER -i wg0 -o ens3 -j ACCEPT' "$WORK/fwd.out" \
        && grep -qF 'iptables -I DOCKER-USER -i ens3 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT' "$WORK/fwd.out" \
        && grep -qF '"ip-forward-no-drop": true  to '"$DOCKER_DAEMON_CONFIG" "$WORK/fwd.out" || return 1
    # the setting of Docker is there, but counts only from its next start
    echo '{ "ip-forward-no-drop": true }' >"$DOCKER_DAEMON_CONFIG"
    DOCTOR_ERRORS=0
    doctor_vpn_forward >"$WORK/fwd.out"
    ((DOCTOR_ERRORS == 1)) && grep -q "Already in" "$WORK/fwd.out" || return 1
    # let through by rules typed by hand: yellow while Docker is not set
    DOCKER_USER_RULES=yes
    rm -f "$DOCKER_DAEMON_CONFIG"
    DOCTOR_ERRORS=0 DOCTOR_WARNINGS=0
    doctor_vpn_forward >"$WORK/fwd.out"
    ((DOCTOR_ERRORS == 0 && DOCTOR_WARNINGS == 1)) && grep -q "disappear at the next restart" "$WORK/fwd.out" || return 1
    printf '{\n  "log-level": "warn",\n  "ip-forward-no-drop" : true\n}\n' >"$DOCKER_DAEMON_CONFIG"
    DOCTOR_WARNINGS=0
    [[ $(doctor_vpn_forward) == *"Traffic of the clients to the Internet: allowed"* ]] && ((DOCTOR_WARNINGS == 0)) || return 1
    # another firewall that refuses by default
    nft() { printf '%s\n' 'table inet other {' '	chain forward {' '		type filter hook forward priority 0; policy drop;' '	}' '}'; }
    DOCTOR_ERRORS=0
    doctor_vpn_forward >"$WORK/fwd.out"
    ((DOCTOR_ERRORS == 1)) && grep -q "another program (table inet other)" "$WORK/fwd.out" || return 1
    # … that lets the VPN out, and every established connection back
    nft() { printf '%s\n' 'table inet other {' '	chain forward {' '		type filter hook forward priority 0; policy drop;' \
        '		ct state established,related accept' '		iifname "wg0" accept' '	}' '}'; }
    DOCTOR_ERRORS=0 DOCTOR_WARNINGS=0
    doctor_vpn_forward >/dev/null
    ((DOCTOR_ERRORS == 0 && DOCTOR_WARNINGS == 0)) || return 1
    # out only, nothing comes back: still blocked
    nft() { printf '%s\n' 'table inet other {' '	chain forward {' '		type filter hook forward priority 0; policy drop;' '		iifname "wg0" accept' '	}' '}'; }
    DOCTOR_ERRORS=0
    doctor_vpn_forward >/dev/null
    ((DOCTOR_ERRORS == 1)) || return 1
    # nothing refused by default (no Docker): fine; part of « doctor_vpn »
    nft() { printf '%s\n' 'table ip seedtunnel {' '	chain postrouting {' '		type nat hook postrouting priority srcnat; policy accept;' '	}' '}'; }
    DOCTOR_ERRORS=0 DOCTOR_WARNINGS=0
    doctor_vpn_forward >/dev/null
    ((DOCTOR_ERRORS == 0 && DOCTOR_WARNINGS == 0)) && declare -f doctor_vpn | grep -q doctor_vpn_forward
)

# Routing is checked for the interfaces the clients cross too, not only for
# the whole server (eth0.100: « / » in the name of sysctl)
doctor_sees_routing_off_for_an_interface() (
    load
    colors_init off
    default_interface() { echo eth0.100; }
    OFF=net.ipv4.conf.eth0/100.forwarding
    sysctl() { if [[ $2 == "$OFF" ]]; then echo 0; else echo 1; fi; }
    DOCTOR_ERRORS=0
    doctor_vpn_routing >"$WORK/route.out"
    cat "$WORK/route.out"
    ((DOCTOR_ERRORS == 1)) && grep -qF "IPv4 routing off for eth0.100" "$WORK/route.out" \
        && grep -qF "sysctl -w net.ipv4.conf.eth0/100.forwarding=1" "$WORK/route.out" || return 1
    OFF=net.ipv4.conf.wg0.forwarding
    DOCTOR_ERRORS=0
    doctor_vpn_routing >"$WORK/route.out"
    ((DOCTOR_ERRORS == 1)) && grep -qF "IPv4 routing off for wg0" "$WORK/route.out" || return 1
    # on everywhere; an interface that is not there (VPN stopped) is skipped
    OFF=none
    sysctl() { if [[ $2 == *wg0* ]]; then return 255; else echo 1; fi; }
    DOCTOR_ERRORS=0
    [[ $(doctor_vpn_routing) == *"IPv4 routing on"* ]] && ((DOCTOR_ERRORS == 0)) || return 1
    # off for the whole server: one line, as before
    sysctl() { echo 0; }
    DOCTOR_ERRORS=0
    doctor_vpn_routing >"$WORK/route.out"
    ((DOCTOR_ERRORS == 1)) && grep -q "IPv4 routing off: the clients" "$WORK/route.out" \
        && declare -f doctor_vpn | grep -q doctor_vpn_routing
)

# The process holding the lock belongs to root: who came in by sudo needs
# « sudo kill » (a plain « kill » is refused)
lock_message_says_sudo_kill() (
    load
    APP_LOCK="$WORK/lock-sudo"
    (
        exec 9<>"$APP_LOCK"
        flock 9
        printf '%s %s %s\n' "$BASHPID" "$(date +%s)" pts/1 >"$APP_LOCK"
        sleep 3
    ) &
    sleep 0.5
    local out pid
    pid=$(cut -d' ' -f1 "$APP_LOCK")
    if out=$(SUDO_USER=debian take_lock 2>&1); then return 1; fi
    echo "$out"
    [[ $out == *"sudo kill $pid"* ]] || return 1
    # logged in as root directly: no sudo
    if out=$(unset SUDO_USER && take_lock 2>&1); then return 1; fi
    wait
    [[ $out == *"kill $pid"* && $out != *"sudo kill"* ]]
)

check "vpn_sync: WireGuard refusing the configuration shows « failed »" vpn_sync_reports_wg_failure
check "vpn_sync: a failure of « wg-quick strip » is seen" vpn_sync_reports_strip_failure
check "vpn_sync: « ok » when every step works" vpn_sync_ok_when_all_steps_work
check "write_if_changed: generator failing (disk full) → file kept" write_keeps_file_when_generator_fails
check "write_if_changed: replacement failing → file kept" write_keeps_file_when_replace_fails
check "write_if_changed: says whether the file changed, sets its mode" write_reports_changed_and_unchanged
check "one-time link: deleted when the file is first opened" share_link_deleted_at_first_opening
check "one-time link: deleted when it expires, not marked as downloaded" share_link_expires
check "translation: French message with its value" french_message
check "translation: missing message stays in English" unknown_message_stays_english
check "language: environment, saved choice, system language" language_detection
check "translation: long texts in French" long_texts_exist_in_french
check "firewall: open TCP ports read from the rules" firewall_ports_parsing
check "lock: the message names the process holding it" lock_message_names_the_holder
check "domain menu: an empty answer goes back, nothing changed" domain_change_empty_answer_goes_back
check "domain menu: same name, certificate kept without a new request" domain_change_same_name_keeps_certificate
check "domain menu: warning and confirmation before replacing the certificate" domain_change_warns_before_replacing_certificate
check "domain menu: B (or Q) goes back when the name points elsewhere" domain_change_back_when_name_points_elsewhere
check "domain menu: new name applied once confirmed" domain_change_applied_once_confirmed
check "firewall: change refused → previous rules back, boot file untouched" firewall_change_refused_restores_previous_rules
check "firewall: first activation refused → no rules left" firewall_first_trial_refused_leaves_nothing
check "firewall: change confirmed → becomes the rules loaded at boot" firewall_change_confirmed_becomes_permanent
check "VPN: a change refused by WireGuard is applied at the next run" vpn_change_failed_then_retried
check "backup: a failed backup leaves no file, never « the latest »" backup_failed_leaves_nothing
check "backup: complete archive, checked, then renamed" backup_complete_and_checked
check "firewall: a failed undo is reported and the automatic undo kept" firewall_undo_failure_keeps_automatic_undo
check "firewall: rules refused once are applied at the next run" firewall_refresh_retried_after_failure
check "firewall: rules that cannot be removed → stays on, nothing deleted" firewall_disable_checked
check "VPN removal: interface still running → keys kept" vpn_uninstall_checked
check "firewall: automatic undo that cannot be cancelled → previous rules back" firewall_rollback_cancel_checked
check "firewall: new rules refused → file loaded at boot unchanged" firewall_refresh_keeps_boot_file
check "firewall: service at boot not enabled → put right by the next run" firewall_boot_service_put_right
check "nginx: a reload that failed is done at the next run" nginx_reload_retried_after_failure
check "SSH: a reload that failed is done at the next run" ssh_reload_retried_after_failure
check "seedbox removal: account not deleted → SFTP restrictions kept" uninstall_stops_when_user_remains
check "backup: a link prepared in advance is never written through" backup_does_not_follow_prepared_link
check "backup: refused in a folder others can write to" backup_refuses_open_folder
check "one-time link: watcher not started → no link" share_refused_without_watcher
check "diagnostics: no automatic backup since it was turned on → warning" doctor_reports_first_backup_missing
check "restore: decrypted files deleted after a failure" restore_cleans_up_after_failure
check "full disk: Transmission refused to start, allowed again with room" diskguard_refuses_start_on_full_disk
check "update: new version failing → previous version back" update_failed_keeps_previous_version
check "update: interrupted earlier (.previous left) → refused, nothing touched" update_refused_when_previous_left
check "update: new version cannot be put in place → previous one back at once" update_second_rename_failure_puts_back
check "update: previous version back but its apply fails → said so" update_old_apply_failure_reported
check "update (git): new version failing → previous commit back and applied" update_git_failed_goes_back
check "update (git): previous commit not back → stop, nothing applied" update_git_head_checked
check "validation: addresses, ports and DNS out of range refused" validators_reject_out_of_range
check "SFTP: restrictions not in force → account suspended, then back" sftp_rule_not_applied_suspends_account
check "SFTP: renamed account suspended before its new name" rename_suspends_account_first
check "one-time link: fingerprint of the self-signed certificate shown" share_shows_selfsigned_fingerprint
check "one-time link: prepared halfway → deleted, no link" share_prepared_halfway_deleted
check "files holding a secret: refused if others can read them" secret_files_must_be_private
check "firewall: « yes » refused without a new SSH login" firewall_yes_needs_new_ssh_login
check "packages: installed ones listed, dependencies included" install_records_what_it_brought
check "packages: removal only takes what seedtunnel installed" purge_only_what_seedtunnel_installed
check "packages: server set up by an older version → its packages still removed" packages_from_older_version_still_removed
check "packages: kept if removing them would take another program" purge_kept_when_it_would_take_others
check "packages: list kept when the installed packages cannot be read" registry_kept_when_list_unreadable
check "Transmission: settings write failing → previous ones whole, Transmission started" transmission_settings_failure_keeps_them
check "Transmission: waits for the disk of the data" transmission_waits_for_data_disk
check "ports 80/443: another program beside nginx is seen" web_ports_other_program_beside_nginx
check "full disk: free space not measurable → said, Transmission left alone" diskguard_warns_when_unmeasurable
check "diagnostics: certificate served refused by browsers → error" doctor_reports_certificate_refused
check "VPN help: the kill switch is explained" vpn_help_explains_kill_switch
check "SFTP: suspension that cannot be done is said, no rename" sftp_suspension_failure_is_said
check "SFTP: restrictions checked from everywhere, all of them" sftp_rule_checked_from_everywhere
check "SFTP: rename failing halfway → old name back" rename_undone_when_a_step_fails
check "firewall: session from the Internet → a login through the VPN does not count" firewall_vpn_login_does_not_count
check "firewall: session through the VPN → a login through the VPN counts" firewall_vpn_session_confirms_through_vpn
check "firewall: session through the VPN → a login from the Internet counts" firewall_internet_login_confirms_vpn_session
check "firewall: a login from the server to its own address does not count" firewall_login_from_server_itself_does_not_count
check "firewall: only the messages written by sshd are read" firewall_only_reads_messages_of_sshd
check "diagnostics: certificate served not checked → warning" doctor_says_certificate_not_checked
check "validation: IPv6 addresses, valid and invalid forms" ipv6_forms
check "restore stopped halfway: how to go back is said" restore_unfinished_says_how_to_go_back
check "SFTP: « keys only » checked (password, keyboard-interactive)" sftp_keys_only_checked
check "SFTP: reactivation of the account checked" sftp_resume_checked
check "SFTP: keys imported all or none" sftp_keys_import_all_or_nothing
check "SFTP: removing a key that cannot be written → file kept" sftp_keys_remove_failure_keeps_file
check "SFTP: rename undone, group not back → said, account suspended" rename_group_undo_checked
check "restore: archive with a link (to /etc/shadow) refused" restore_refuses_links
check "restore: links of Let's Encrypt to its certificates accepted" restore_accepts_letsencrypt_links
check "restore: settings that could run a command refused" restore_refuses_code_in_settings
check "restore: a client's settings that could run a command refused" restore_refuses_code_in_client
check "restore: real backup (WireGuard files of the clients) accepted" restore_accepts_real_backup
check "settings files: what state_write writes is accepted, code is not" state_files_round_trip_safe
check "backup: settings changed meanwhile → archive made again, never mixed" backup_redone_when_settings_change
check "backup: an older backup is never replaced" backup_never_replaces_older
check "backup: passphrase that cannot be written → the previous one kept" backup_passphrase_saved_whole
check "back: VPN, add a client (empty name)" vpn_add_client_can_go_back
check "back: VPN, show, link and revoke a client (and « no »)" vpn_client_actions_can_go_back
check "back: VPN, a client that does not exist is asked again" vpn_pick_client_asks_again
check "back: VPN, change of settings (each question, and « no »)" vpn_settings_can_go_back
check "back: VPN installation (address, name of the first client)" vpn_install_can_go_back
check "back: seedbox installation (each question, and « no »)" seedbox_install_can_go_back
check "back: seedbox, user and password (and « no »)" seedbox_credentials_can_go_back
check "back: SSH keys, add and remove (wrong answers asked again)" sftp_keys_menu_can_go_back
check "back: banned IP addresses (wrong address asked again)" unban_can_go_back
check "back: domain name at the installation" seedbox_domain_install_can_go_back
check "back: passphrase of a backup (wrong entries asked again)" backup_passphrase_can_go_back
check "back: backup now and weekly backup (empty passphrase)" backup_create_and_weekly_can_go_back
check "back: restore, path of the file (asked again if missing)" backup_menu_can_go_back
check "back: restore, wrong passphrase asked again, then back" restore_wrong_passphrase_asked_again
check "df failing: free space unreadable, nothing stops (diagnostics, full disk)" df_failure_does_not_stop
check "network settings: one value off (IPv6 too) → said, and loaded again" net_hardening_checked_everywhere
check "diagnostics: NAT made for another network interface → error" doctor_nat_checks_interface
check "firewall: rules that do not refuse by default → said (doctor, status)" firewall_policy_checked
check "diagnostics: weekly backup without timer or passphrase → error" doctor_weekly_backup_needs
check "diagnostics: update cut short (.previous left) → said" doctor_reports_unfinished_update
check "services: enabled at boot and running, nothing done when they are" services_put_right
check "VPN: not enabled at boot → said" vpn_enable_failure_said
check "full disk: Transmission that does not start again → kept, said" diskguard_start_failure_said
check "validation: IPv4 without leading zero, DNS, public address of the VPN" validators_stricter
check "update (git): only vX.Y.Z tags whose code says that version" update_git_tag_checked
check "language: asked until 1 or 2, saved file written aside" language_asked_again
check "shortcut: link elsewhere put right, another program left alone" shortcut_put_right
check "commands: unknown, or arguments too many → refused before anything" commands_refused_first
check "one-time link: not enough room in /run → no link" share_refused_without_room
check "one-time link: its page is not counted, its file is" share_page_not_limited
check "VPN: NAT rules refused → the clients are not changed" vpn_sync_checks_nat_first
check "VPN: test interface left behind → removed before the check" vpn_kernel_check_cleans_up
check "VPN: new port with a session through the VPN → asked, no by default" vpn_port_change_through_vpn
check "firewall: the message says which new login counts" firewall_message_says_rule
check "weekly backup: new passphrase → the older backups keep theirs (said)" backup_new_passphrase_warns
check "translations: empty, or a stray %, refused" i18n_check_stricter
check "seedbox: the home page asks for the password first" nginx_home_asks_password_first
check "dates: today, yesterday, N days ago (EN, FR)" backup_dates_in_words
check "restore of an older backup: the weekly backup keeps its passphrase" restore_keeps_weekly_passphrase
check "restore: weekly backup without any passphrase → turned off, said" restore_weekly_without_passphrase_off
check "restore: another SFTP account than this server → refused first" restore_refuses_other_sftp_account
check "restore: account already on this server, or web ports taken → refused" restore_refuses_existing_account
check "restore: VPN or seedbox of this server missing from the backup → refused" restore_refuses_missing_parts
check "restore: backup without firewall → the firewall of this server stays on" restore_keeps_firewall
check "restore: marked while the settings are replaced, until the end" restore_marks_until_finished
check "diagnostics: restore cut short → said, with the way back" doctor_reports_interrupted_restore
check "firewall at boot: loaded after nftables.service" firewall_after_nftables_service
check "firewall rules: loaded rules in words, client ports" firewall_rules_in_plain_words
check "firewall rules: what differs from the settings is said" firewall_rules_differences_said
check "firewall rules: off → said, client ports still listed" firewall_rules_when_off
check "report: private values replaced, the useful ones kept" report_replaces_private_values
check "report: without a seedbox, saved for the account of sudo (600)" report_saved_without_seedbox
check "report: longest names first, common words and VPN addresses kept" report_longest_first_common_words_kept
check "restore that fails: the way back also removes its marker" restore_failure_says_marker
check "report: version numbers of packages are not taken for addresses" report_keeps_version_numbers
check "nftables: a table is only deleted while it is there (no error in the log)" nft_tables_deleted_only_when_there
check "interface: lengths in characters, in any locale (accents, ●, ─, colors)" ui_counts_characters
check "interface: long text wrapped, a path split but never shortened" ui_wraps_without_losing_text
check "interface: colors with a terminal, none with NO_COLOR or « dumb »; 256 or 8" colors_follow_terminal_and_no_color
check "interface: no line wider than the screen (20 to 200 columns, EN/FR, colors)" preview_fits_every_width
check "interface: same screens whether the locale counts characters or bytes" preview_same_in_every_locale
check "interface: blocks from 80 columns, list below; menu in two columns from 71" preview_layout_follows_width
check "interface: table columns aligned with accents and colors" ui_table_aligned_with_accents
check "interface: answer without spaces, Q after an action, no question outside menus" ui_choice_and_pause_answers
check "menus: B or empty goes back, R refreshes, Q leaves seedtunnel from a submenu" menus_keys_b_r_q
check "menus: an action that fails comes back to the menu (set -e works inside)" action_error_comes_back_to_menu
check "menus: Q after an action of a submenu leaves seedtunnel" quit_from_an_action
check "home screen: each state of VPN, seedbox, firewall, disk and backup" home_states
check "home screen: every state fits its block (9 characters, EN/FR)" home_state_words_fit_blocks
check "menus: the real screens fit the screen (EN/FR, 40 and 80 columns)" menus_fit_the_screen
check "log: cut every month (logrotate), from the installation and apply" log_rotation_rule
check "log: a service stopped writes its own title (never a failure)" log_titles_before_service_stops
check "update: the version replaced is kept (one only)" update_keeps_previous_version
check "update back: the version kept comes back and applies the settings" update_back_puts_previous_back
check "update back: older version failing → the newer one comes back" update_back_failure_puts_newer_back
check "update back: nothing kept, not older, « no », git → nothing changed" update_back_refused_when_nothing_to_go_back_to
check "update from 2.0: apply keeps a copy of the version replaced" apply_saves_previous_for_back
check "menu: update screen offers the way back when a version is kept" update_menu_offers_way_back
check "diagnostics: BitTorrent port open, closed (warning) or not tested" doctor_tests_torrent_port
check "SFTP password: warning once there is a key, yellow in the menus" sftp_password_warning

check "diagnostics: traffic of the VPN blocked by Docker or another firewall" doctor_sees_vpn_traffic_blocked
check "diagnostics: IPv4 routing off for the VPN or the way out" doctor_sees_routing_off_for_an_interface
check "lock: « sudo kill » for whoever came in by sudo" lock_message_says_sudo_kill
printf '\n\033[1m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
((FAIL == 0))
