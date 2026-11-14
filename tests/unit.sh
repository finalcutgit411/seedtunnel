#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
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
    SSHD_RUNTIME_DIR="$WORK/run-sshd"
    mkdir -p "$APP_STATE_DIR"
    local library
    for library in i18n ui vpn seedbox firewall share diskguard backup update doctor menu; do
        # shellcheck source=/dev/null
        . "$ROOT/lib/$library.sh"
    done
    i18n_load en
    # never the backups of the machine that runs the tests (/root, /home)
    BACKUP_COPIED=()
    # the tests do not run as root: the command, as the current user
    runuser() {
        while [[ $1 != -- ]]; do shift; done
        shift
        "$@"
    }
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
    printf '%s\n' "$dir" file.conf 20 "$WORK/mark" >"$WORK/share-job1"
    bash -c "$SHARE_WATCHER" watcher "$WORK/share-job1" &
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
    printf '%s\n' "$dir" file.conf 1 "$WORK/mark2" >"$WORK/share-job2"
    bash -c "$SHARE_WATCHER" watcher "$WORK/share-job2"
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
    # as in the script: an empty answer leaves the variable alone
    ask_back() {
        local _back_answer
        ask _back_answer
        [[ -n $_back_answer ]] || return 1
        printf -v "$1" '%s' "$_back_answer"
    }
    # the choice of a menu is an answer like the others
    ui_ask_choice() { ask "$1"; }
}

answers() { printf '%s\n' "$@" >"$WORK/answers"; }

# went_back COMMAND [ARGUMENTS…] — the action went back without doing
# anything: status 0 and WENT_BACK=1 (never status 1, see lib/common.sh)
went_back() {
    WENT_BACK=0
    "$@" >"$WORK/went-back.out" 2>&1 || {
        cat "$WORK/went-back.out"
        return 1
    }
    ((WENT_BACK == 1))
}

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
    went_back seedbox_change_domain || return 1
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
    went_back seedbox_change_domain || return 1
    domain_untouched || return 1
    # Q, the key of 1.2.x, still goes back
    answers "elsewhere.test" "q"
    went_back seedbox_change_domain || return 1
    domain_untouched
)

# The screen: what the seedbox is now in a green frame (its certificate, its
# end and renewal with Let's Encrypt, the public IP), then the two choices
domain_change_screen() (
    domain_menu_load
    colors_init off
    UI_COLUMNS=80
    certificate_days_left() { echo 76; }
    answers ""
    seedbox_change_domain >"$WORK/domain.out" 2>&1
    cat "$WORK/domain.out"
    local out
    out=$(<"$WORK/domain.out")
    [[ $out == *"┌─ ● Right now"*"│ Address      https://old.example.org/"*"│ Certificate  Let's Encrypt"*"│ Expires      2027-01-29 (in 76 days)"*"│ Renewed      automatically"*"│ Public IP    203.0.113.10"* ]] || return 1
    [[ $out == *"New name of the seedbox, at your choice:"*"● a domain name (yours, or the one given by the provider"*"● or the IP address of the server: self-signed certificate"* ]] || return 1
    # the address looked for before the screen, not on it
    [[ ${out#*Right now} != *"Looking for the public IP address"* ]] || return 1
    # self-signed: said so, nothing about an end or a renewal
    SEEDBOX_CERTIFICATE=selfsigned
    SEEDBOX_DOMAIN=203.0.113.10
    answers ""
    seedbox_change_domain >"$WORK/domain.out" 2>&1
    out=$(<"$WORK/domain.out")
    [[ $out == *"│ Certificate  self-signed (browser warning to accept)"* && $out != *Expires* && $out != *Renewed* ]] || {
        printf '%s\n' "$out"
        return 1
    }
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

# On trial: what to do in a pink frame; « yes » before any new SSH login: a
# red frame with the time left, and the question again; the VPN said only when
# there is one
firewall_trial_frames() (
    firewall_trial_load
    colors_init off
    UI_COLUMNS=80
    vpn_installed() { return 0; }
    # no login the first time, one the second time
    journalctl() {
        if [[ -e $WORK/fw/second ]]; then
            echo "Accepted publickey for admin from 203.0.113.5 port 50000 ssh2: ED25519 SHA256:x"
        else
            touch "$WORK/fw/second"
        fi
    }
    printf 'yes\nyes\n' | firewall_enable >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    firewall_enabled || return 1
    grep -q "┌─ ● New SSH connection" "$WORK/fw/out" && grep -q "┌─ ! No new SSH connection yet" "$WORK/fw/out" \
        && grep -q "the VPN (10.8.0.1), only if this window" "$WORK/fw/out" \
        && grep -qE "│ Time left: 1 min [0-9]+ s\. +│" "$WORK/fw/out" || return 1
    # without the VPN: nothing about it
    firewall_trial_load
    colors_init off
    vpn_installed() { return 1; }
    printf 'yes\n' | firewall_enable >"$WORK/fw/out" 2>&1
    grep -q "New SSH connection" "$WORK/fw/out" && ! grep -q "Through the" "$WORK/fw/out" || {
        cat "$WORK/fw/out"
        return 1
    }
    [[ $(firewall_duration 92) == "1 min 32 s" && $(firewall_duration 45) == "45 s" && $(firewall_duration -3) == "0 s" ]]
)

# --- firewall: every change of state checked ------------------------------

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

# A name that differs from a client only by the case of its letters is that
# client: refused by the command and by the menu (Windows cannot keep
# PHONE.conf beside phone.conf, and the two are mixed up on screen)
vpn_client_names_ignore_case() (
    back_load
    mkdir -p "$VPN_CLIENTS_DIR"
    (
        CLIENT_NUMBER=1
        CLIENT_PUBLIC_KEY="yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
        CLIENT_PRESHARED_KEY=$CLIENT_PUBLIC_KEY
        state_write "$VPN_CLIENTS_DIR/phone.env" CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY
    )
    [[ $(vpn_client_same_name PHONE) == phone && $(vpn_client_same_name Phone) == phone ]] || return 1
    ! vpn_client_same_name tablet || return 1
    if (vpn_add_client PHONE) >"$WORK/case.out" 2>&1; then
        cat "$WORK/case.out"
        return 1
    fi
    grep -q 'Client "phone" already exists.' "$WORK/case.out" && [[ ! -e $VPN_CLIENTS_DIR/PHONE.env ]] || return 1
    local name
    answers "PHONE" "tablet"
    vpn_ask_client_name name >"$WORK/case.out" 2>&1 || return 1
    [[ $name == tablet ]] && grep -q 'Client "phone" already exists.' "$WORK/case.out"
)

# --- VPN: NAT rules loaded by systemd, not by wg-quick (AppArmor, Ubuntu 26.04) ----

vpn_nat_loaded_by_systemd() (
    load
    mkdir -p "$VPN_CLIENTS_DIR"
    echo "server-key" >"$VPN_STATE_DIR/server.key"
    vpn_generate_server_conf >"$WORK/wg0.test" || return 1
    if grep -qE '^(Pre|Post)(Up|Down)' "$WORK/wg0.test"; then
        echo "wg0.conf still makes wg-quick run a command"
        return 1
    fi
    vpn_generate_systemd_dropin >"$WORK/dropin.test" || return 1
    cat "$WORK/dropin.test"
    grep -qx '\[Service\]' "$WORK/dropin.test" \
        && grep -qxF "ExecStartPost=/usr/sbin/nft -f $VPN_NAT_RULES" "$WORK/dropin.test" \
        && grep -qxF "ExecStopPost=-/usr/sbin/nft delete table ip seedtunnel" "$WORK/dropin.test"
)

# The clients cannot reach each other, and nothing from outside the tunnel
# reaches them but the replies and their open port. In the table of the VPN:
# there whenever the VPN runs, firewall on or off. Policy « accept »: the
# traffic of other programs (Docker) is not cut.
vpn_clients_isolated_and_protected() (
    load
    VPN_STATE_DIR="$WORK/vpn-forward"
    VPN_CLIENTS_DIR="$VPN_STATE_DIR/clients"
    VPN_OUT_INTERFACE=ens3
    rm -rf "$VPN_STATE_DIR"
    mkdir -p "$VPN_CLIENTS_DIR"
    (
        CLIENT_NUMBER=1
        CLIENT_PUBLIC_KEY="yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
        CLIENT_PRESHARED_KEY=$CLIENT_PUBLIC_KEY
        state_write "$VPN_CLIENTS_DIR/phone.env" CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY
    )
    local rules forward
    rules=$(vpn_generate_nat_rules) || return 1
    # the rules of the chain, without comments nor indentation
    forward=$(awk '/^    chain forward \{/ { on = 1; next }
        on && /^    \}/ { exit }
        on && !/^[[:space:]]*(#|$)/ { sub(/^[[:space:]]+/, ""); print }' <<<"$rules")
    printf '%s\n' "$forward"
    [[ $forward == 'type filter hook forward priority filter; policy accept;
iifname "wg0" oifname "wg0" drop
oifname "wg0" ct state established,related accept
oifname "wg0" ct status dnat accept
oifname "wg0" drop' ]] || return 1
    # the open port of the client is still forwarded to it
    grep -qF 'iifname "ens3" meta l4proto { tcp, udp } th dport 60001 dnat to 10.8.0.2' <<<"$rules"
)

# The addition is written, and systemd reloaded, before the VPN starts
vpn_apply_writes_dropin_before_start() (
    load
    vpn_load
    VPN_SYSTEMD_DROPIN="$WORK/wg-dropin/seedtunnel.conf"
    WIREGUARD_CONF="$WORK/wg0.conf"
    VPN_SYSCTL_FILE="$WORK/90-vpn.conf"
    : >"$WORK/vpn-calls"
    apt_install() { :; }
    firewall_refresh() { :; }
    net_hardening_apply() { :; }
    default_interface() { echo ens3; }
    sysctl() { echo 1; }
    chown() { :; }
    # /etc/wireguard: not for the tests (not root)
    install() {
        local argument
        local -a arguments=()
        for argument in "$@"; do [[ $argument == /etc/wireguard ]] || arguments+=("$argument"); done
        command install "${arguments[@]}"
    }
    wg() {
        case $1 in
            genkey) echo private ;;
            pubkey) echo public ;;
        esac
    }
    systemctl() {
        echo "systemctl $*" >>"$WORK/vpn-calls"
        [[ $1 != is-active ]]
    }
    vpn_apply </dev/null >"$WORK/vpn-apply.out" 2>&1 || {
        cat "$WORK/vpn-apply.out"
        return 1
    }
    cat "$WORK/vpn-calls"
    local reload start
    reload=$(grep -n 'systemctl daemon-reload' "$WORK/vpn-calls" | head -n 1 | cut -d: -f1)
    start=$(grep -n 'systemctl enable --now wg-quick@wg0' "$WORK/vpn-calls" | head -n 1 | cut -d: -f1)
    [[ -s $VPN_SYSTEMD_DROPIN && -n $reload && -n $start ]] && ((reload < start)) || return 1
    # run again: nothing new, no reload
    : >"$WORK/vpn-calls"
    vpn_apply </dev/null >"$WORK/vpn-apply.out" 2>&1 || return 1
    ! grep -q daemon-reload "$WORK/vpn-calls"
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
    # through the site of the seedbox (the site of the links: see
    # links_share_through_vpn_address)
    seedbox_installed() { return 0; }
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
    systemctl() {
        echo "systemctl $*" >>"$WORK/share-calls"
        # the main process of the watcher
        if [[ $1 == show ]]; then echo 4242; fi
    }
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

# The lock goes over to the new version without ever being free: a command
# started meanwhile is refused. A version that does not know this (before
# 1.0.4) gets it let go just before, as it expects.
update_hands_the_lock_over() (
    load
    APP_LOCK="$WORK/lock-update"
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app" "$APP_LOCK"
    mkdir -p "$APP_DIR/lib"
    echo 'SEEDTUNNEL_LOCK_HANDED_OVER' >"$APP_DIR/lib/common.sh"
    # the new version takes the lock with the real take_lock, then a command
    # started meanwhile tries to take it
    printf '#!/bin/bash\n. "%s/lib/common.sh"\nAPP_LOCK="%s"\ntake_lock\nif flock -n "$APP_LOCK" true; then echo free; else echo held; fi\n' \
        "$ROOT" "$APP_LOCK" >"$APP_DIR/seedtunnel.sh"
    chmod +x "$APP_DIR/seedtunnel.sh"
    exec 9<>"$APP_LOCK"
    flock -n 9 || return 1
    local out
    out=$(update_run_apply 2>&1)
    [[ $out == held ]] || {
        echo "$out"
        return 1
    }
    # still held by this version once the new one is done
    if flock -n "$APP_LOCK" true; then return 1; fi
    # a version before 1.0.4: the lock is let go, it takes it as usual
    : >"$APP_DIR/lib/common.sh"
    update_run_apply >"$WORK/lock-update.out" 2>&1
    [[ $(<"$WORK/lock-update.out") == held && ! /proc/self/fd/9 -ef $APP_LOCK ]] && flock -n "$APP_LOCK" true
)

# The latest version read without jq (installed with the VPN or the seedbox
# only): seedtunnel updates before them
update_without_jq() (
    load
    jq() {
        echo "jq used" >>"$WORK/jq-used"
        return 127
    }
    rm -f "$WORK/jq-used"
    [[ $(printf '{\n  "url": "x",\n  "tag_name": "v1.2.3",\n  "name": "v1.2.3"\n}\n' | update_tag_from_json) == v1.2.3 ]] || return 1
    [[ $(printf '{"url":"x","tag_name" : "v2.0.0","name":"v2.0.0"}' | update_tag_from_json) == v2.0.0 ]] || return 1
    [[ -z $(printf '{"message":"Not Found"}' | update_tag_from_json) ]] || return 1
    # the same version published: up to date, said as such
    curl() { printf '{\n  "tag_name": "v%s",\n  "draft": false\n}\n' "$APP_VERSION"; }
    update_from_release >"$WORK/update.out" 2>&1 || return 1
    grep -q "seedtunnel is up to date (version $APP_VERSION)" "$WORK/update.out" || return 1
    # nothing read: said, with the address
    curl() { return 22; }
    if (update_from_release) >"$WORK/update.out" 2>&1; then return 1; fi
    grep -q "Cannot find the latest version published on github.com/$APP_REPO" "$WORK/update.out" && [[ ! -e $WORK/jq-used ]]
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
    update_versions_make "${UPDATE_NEW_STATUS:-7}"
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
    # on two lines in 80 columns: the same once joined
    [[ $(tr -d ' \n' <"$WORK/share-fp.out") == *"$(openssl x509 -in "$SEEDBOX_SSL_DIR/selfsigned.crt" -noout -fingerprint -sha256 | cut -d= -f2)"* ]] || return 1
    (($(awk 'length > 79' "$WORK/share-fp.out" | wc -l) == 0))
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

# apt_cache_policy PACKAGE → what « apt-cache policy » says of a package APT knows
apt_cache_policy() {
    printf '%s:\n  Installed: (none)\n  Candidate: 1.0-1\n  Version table:\n' "$1"
    printf '     1.0-1 500\n        500 http://deb.debian.org/debian trixie/main amd64 Packages\n%.0s' {1..2000}
}

packages_load() {
    load
    # a new server: nothing installed by seedtunnel yet
    rm -f "$APP_STATE_DIR/packages" "$APP_STATE_DIR/vpn.conf" "$APP_STATE_DIR/seedbox.conf" "$WORK/apt-calls"
    printf '%s\n' curl nginx unrelated >"$WORK/installed"
    package_installed() { grep -qxF -- "$1" "$WORK/installed"; }
    packages_installed_list() { LC_ALL=C sort "$WORK/installed"; }
    # APT has a version of every package (and a long table of versions after
    # it, as on a real server: more than a pipe holds)
    apt-cache() { apt_cache_policy "$2"; }
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

# Transmission 4.1 (Ubuntu 26.04): « preferred_transports » decides uTP. Left
# as it was, uTP stayed on and every « apply » restarted Transmission.
transmission41_utp_off_without_restarts() (
    load
    local file41="$WORK/settings41.json"
    TRANSMISSION_DROPIN="$WORK/dropin41/seedtunnel.conf"
    SEEDBOX_DATA_DIR="$WORK/data"
    SEEDBOX_USER=lancelot
    SEEDBOX_HASH_TRANSMISSION='{0123456789abcdef'
    # as Transmission 4.1 leaves it after its first start
    printf '{"utp-enabled": true, "preferred_transports": ["utp", "tcp"], "umask": "002"}\n' >"$file41"
    transmission_settings_file() { echo "$file41"; }
    diskguard_stopped() { return 1; }
    chown() { :; }
    # Transmission 4.1 writes its settings when it stops, « utp-enabled »
    # following the « preferred_transports » it started with
    systemctl() {
        echo "systemctl $*" >>"$WORK/tr41-calls"
        if [[ $1 == stop ]]; then
            jq '."utp-enabled" = (."preferred_transports" | index("utp") != null)' "$file41" >"$file41.x"
            mv "$file41.x" "$file41"
        fi
        return 0
    }
    seedbox_apply_transmission &>/dev/null || return 1
    grep -q "systemctl stop transmission-daemon" "$WORK/tr41-calls" || return 1
    # the names of the settings changed, in the log under the title of the step
    awk '/^=== /{ title = $0 } /settings to change: .*utp-enabled/{ print title }' "$APP_LOG" | tail -n 1 | grep -q "Stopping Transmission" || return 1
    # again, twice: nothing to change any more
    rm -f "$WORK/tr41-calls"
    seedbox_apply_transmission &>/dev/null && seedbox_apply_transmission &>/dev/null || return 1
    cat "$WORK/tr41-calls" "$file41"
    ! grep -qE "systemctl (stop|restart) transmission-daemon" "$WORK/tr41-calls" \
        && [[ $(jq -c '[."utp-enabled", ."preferred_transports"]' "$file41") == '[false,["tcp"]]' ]] || return 1
    # Transmission 4.0 and before (no « preferred_transports »): not added
    printf '{"utp-enabled": true}\n' >"$file41"
    seedbox_apply_transmission &>/dev/null || return 1
    [[ $(jq -c 'has("preferred_transports")' "$file41") == false ]]
)

# Settings of an older Transmission (a backup of Debian 13 restored on Ubuntu
# 26.04): Transmission 4.1 has no « preferred_transports » in them, and would
# start with uTP on. TCP only from the start; nothing added for an older one.
transmission41_utp_off_after_older_settings() (
    load
    local file="$WORK/settings-old.json" tested
    TRANSMISSION_DROPIN="$WORK/dropin-old/seedtunnel.conf"
    SEEDBOX_DATA_DIR="$WORK/data"
    SEEDBOX_USER=lancelot
    SEEDBOX_HASH_TRANSMISSION='{0123456789abcdef'
    transmission_settings_file() { echo "$file"; }
    diskguard_stopped() { return 1; }
    chown() { :; }
    systemctl() { return 0; }
    for tested in "4.1.1+dfsg-1ubuntu1.1" "4.1.0~beta4" "4.1.0~beta2+dfsg-3+deb13u1" "4.0.6-1" "3.00-2.1+deb12u1" ""; do
        printf '{"utp-enabled": true, "umask": "002"}\n' >"$file"
        dpkg-query() { if [[ -n $tested ]]; then echo "$tested"; else return 1; fi; }
        seedbox_apply_transmission &>/dev/null || return 1
        case $tested in
            4.1.1* | 4.1.0~beta4)
                [[ $(jq -c '[."utp-enabled", ."preferred_transports"]' "$file") == '[false,["tcp"]]' ]] || {
                    echo "$tested: $(<"$file")"
                    return 1
                }
                ;;
            *)
                [[ $(jq -c '[."utp-enabled", has("preferred_transports")]' "$file") == '[false,false]' ]] || {
                    echo "$tested: $(<"$file")"
                    return 1
                }
                ;;
        esac
    done
)

# Ubuntu 26.04: the AppArmor profile of Transmission only allows its own
# folder, every download in the data folder failed. The data folder in the
# additions of the profile, reloaded when they change; nothing without it.
apparmor_load() {
    load
    mkdir -p "$WORK/aa/local"
    TRANSMISSION_APPARMOR_PROFILE="$WORK/aa/transmission"
    TRANSMISSION_APPARMOR_LOCAL="$WORK/aa/local/transmission-daemon"
    APPARMOR_ENABLED_FILE="$WORK/aa/enabled"
    echo Y >"$APPARMOR_ENABLED_FILE"
    printf 'profile transmission-daemon {\n  include if exists <local/transmission-daemon>\n}\n' >"$TRANSMISSION_APPARMOR_PROFILE"
    rm -f "$TRANSMISSION_APPARMOR_LOCAL" "$WORK/aa-calls"
    SEEDBOX_DATA_DIR="$WORK/seed box"
    chown() { :; }
    apparmor_parser() { echo "apparmor_parser $*" >>"$WORK/aa-calls"; }
}

transmission_apparmor_rules() (
    apparmor_load
    seedbox_apply_apparmor >/dev/null 2>&1 || return 1
    cat "$TRANSMISSION_APPARMOR_LOCAL"
    grep -qxF "\"$WORK/seed box/\" r," "$TRANSMISSION_APPARMOR_LOCAL" \
        && grep -qxF "\"$WORK/seed box/**\" rwk," "$TRANSMISSION_APPARMOR_LOCAL" \
        && [[ $(<"$WORK/aa-calls") == "apparmor_parser -r $TRANSMISSION_APPARMOR_PROFILE" ]] || return 1
    # again: nothing to change, nothing reloaded
    seedbox_apply_apparmor >/dev/null 2>&1 || return 1
    (($(wc -l <"$WORK/aa-calls") == 1)) || return 1
    # another data folder: written and reloaded again
    SEEDBOX_DATA_DIR="$WORK/data2"
    seedbox_apply_apparmor >/dev/null 2>&1 || return 1
    grep -qxF "\"$WORK/data2/**\" rwk," "$TRANSMISSION_APPARMOR_LOCAL" && (($(wc -l <"$WORK/aa-calls") == 2)) || return 1
    # reloading fails: said, never fatal
    apparmor_parser() { return 1; }
    SEEDBOX_DATA_DIR="$WORK/data3"
    seedbox_apply_apparmor >"$WORK/aa.out" 2>&1 || return 1
    grep -q "could not be reloaded" "$WORK/aa.out" || return 1
    # AppArmor off: written, nothing loaded
    apparmor_parser() { echo "apparmor_parser $*" >>"$WORK/aa-calls"; }
    echo N >"$APPARMOR_ENABLED_FILE"
    SEEDBOX_DATA_DIR="$WORK/data4"
    seedbox_apply_apparmor >/dev/null 2>&1 || return 1
    (($(wc -l <"$WORK/aa-calls") == 2)) || return 1
    # removal: our rules go, the profile is reloaded
    echo Y >"$APPARMOR_ENABLED_FILE"
    seedbox_remove_apparmor >/dev/null 2>&1 || return 1
    [[ ! -e $TRANSMISSION_APPARMOR_LOCAL ]] && (($(wc -l <"$WORK/aa-calls") == 3)) || return 1
    # a file of the administrator stays
    echo "/mnt/disk/** rw," >"$TRANSMISSION_APPARMOR_LOCAL"
    seedbox_remove_apparmor >/dev/null 2>&1 || return 1
    [[ -s $TRANSMISSION_APPARMOR_LOCAL ]] || return 1
    # without the profile (Debian, Ubuntu 24.04): nothing written
    rm -f "$TRANSMISSION_APPARMOR_PROFILE" "$TRANSMISSION_APPARMOR_LOCAL"
    seedbox_apply_apparmor >/dev/null 2>&1 || return 1
    [[ ! -e $TRANSMISSION_APPARMOR_LOCAL ]]
)

doctor_sees_transmission_apparmor() (
    apparmor_load
    journalctl() { :; }
    # rules missing: downloads fail
    doctor_transmission_apparmor >"$WORK/aa-doctor.out" 2>&1
    cat "$WORK/aa-doctor.out"
    grep -q "AppArmor keeps Transmission out of" "$WORK/aa-doctor.out" || return 1
    # in place, nothing refused since: fine
    seedbox_apply_apparmor >/dev/null 2>&1 || return 1
    doctor_transmission_apparmor >"$WORK/aa-doctor.out" 2>&1
    grep -q "AppArmor lets Transmission write to" "$WORK/aa-doctor.out" || return 1
    # in place, but refused since (profile not reloaded)
    journalctl() { echo 'audit: apparmor="DENIED" operation="mknod" profile="transmission-daemon" name="/x"'; }
    doctor_transmission_apparmor >"$WORK/aa-doctor.out" 2>&1
    grep -q "AppArmor refused Transmission 1 time(s)" "$WORK/aa-doctor.out" || return 1
    # without the profile: no line at all
    rm -f "$TRANSMISSION_APPARMOR_PROFILE"
    doctor_transmission_apparmor >"$WORK/aa-doctor.out" 2>&1
    [[ ! -s $WORK/aa-doctor.out ]]
)

transmission_waits_for_data_disk() (
    load
    SEEDBOX_DATA_DIR=/srv/seedbox
    transmission_generate_dropin | grep -qxF "RequiresMountsFor=/srv/seedbox"
)

# Documents kept when the account was deleted (then owned by root): given back
# to the account created again (restore, new installation), never through a
# link; a hard link to a download leaves the download to its owner. Nothing
# done when they already belong to the account.
sftp_documents_given_back() (
    load
    install_without_owner
    local data="$WORK/data-docs" calls="$WORK/chown-calls"
    rm -rf "$data" "$WORK/fake-bin"
    SEEDBOX_DATA_DIR=$data
    SEEDBOX_USER=lancelot
    mkdir -p "$data/documents/sub" "$data/complete" "$WORK/fake-bin"
    echo a >"$data/documents/a.txt"
    echo b >"$data/documents/sub/b.txt"
    ln -s /etc/passwd "$data/documents/link"
    echo iso >"$data/complete/dl.iso"
    # a download belongs to the account of Transmission, never to root
    if ((EUID == 0)); then command chown nobody "$data/complete/dl.iso"; fi
    ln "$data/complete/dl.iso" "$data/documents/dl.iso"
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>"%s"\n' "$calls" >"$WORK/fake-bin/chown"
    chmod +x "$WORK/fake-bin/chown"
    : >"$calls"
    PATH="$WORK/fake-bin:$PATH" seedbox_apply_dirs >"$WORK/docs.out" 2>&1 || {
        cat "$WORK/docs.out"
        return 1
    }
    cat "$WORK/docs.out" "$calls"
    grep -q "Giving the documents back to lancelot" "$WORK/docs.out" || return 1
    grep -qx -- -h "$calls" && grep -qx lancelot:lancelot "$calls" || return 1
    local path
    for path in documents documents/a.txt documents/sub documents/sub/b.txt documents/link; do
        grep -qxF "$data/$path" "$calls" || {
            echo "not given back: $path"
            return 1
        }
    done
    ! grep -q 'dl.iso' "$calls" || return 1
    # already the owner (the account was not deleted): nothing
    SEEDBOX_USER=$(id -un)
    : >"$calls"
    PATH="$WORK/fake-bin:$PATH" seedbox_apply_dirs >"$WORK/docs.out" 2>&1 || return 1
    [[ ! -s $calls ]] && ! grep -q "Giving the documents back" "$WORK/docs.out"
)

# --- Transmission: settings private, no program run at the end of a download ---

# No program run by Transmission: the setting of Transmission 3, and the two
# more of Transmission 4 (never written for Transmission 3, which would drop
# them: Transmission restarted at every run)
transmission_scripts_turned_off() (
    load
    local file="$WORK/settings-scripts.json" tested
    TRANSMISSION_DROPIN="$WORK/dropin-scripts/seedtunnel.conf"
    TRANSMISSION_STATE_DIR="$WORK/tr-state-scripts"
    SEEDBOX_DATA_DIR="$WORK/data"
    SEEDBOX_USER=lancelot
    SEEDBOX_HASH_TRANSMISSION='{0123456789abcdef'
    mkdir -p "$TRANSMISSION_STATE_DIR"
    transmission_settings_file() { echo "$file"; }
    diskguard_stopped() { return 1; }
    chown() { :; }
    systemctl() { return 0; }
    for tested in "4.1.1+dfsg-1ubuntu1.1" "4.0.6-1" "3.00-2.1+deb12u1"; do
        printf '%s\n' '{"script-torrent-done-enabled": true, "script-torrent-done-filename": "/srv/seedbox/documents/x"}' >"$file"
        dpkg-query() { echo "$tested"; }
        seedbox_apply_transmission &>/dev/null || return 1
        # turned off, and the name of the program set emptied too
        case $tested in
            3.*) [[ $(jq -c '[."script-torrent-done-enabled", ."script-torrent-done-filename", has("script-torrent-added-enabled"), has("script-torrent-done-seeding-enabled")]' "$file") == '[false,"",false,false]' ]] ;;
            *) [[ $(jq -c '[."script-torrent-done-enabled", ."script-torrent-added-enabled", ."script-torrent-done-seeding-enabled", ."script-torrent-done-filename", ."script-torrent-added-filename", ."script-torrent-done-seeding-filename"]' "$file") == '[false,false,false,"","",""]' ]] ;;
        esac || {
            echo "$tested: $(<"$file")"
            return 1
        }
    done
)

# The umask of Transmission compared by its value: the text of Transmission 4
# (« "002" ») is right for Transmission 4, but Transmission 3 does not read it
# (and writes 0 in its place: downloads writable by every account). Settings of
# Transmission 4 restored on Debian 12 are written again with 2; 0 always is.
transmission_umask_by_version() (
    load
    local file="$WORK/settings-umask.json" tested start
    TRANSMISSION_DROPIN="$WORK/dropin-umask/seedtunnel.conf"
    TRANSMISSION_STATE_DIR="$WORK/tr-state-umask"
    SEEDBOX_DATA_DIR="$WORK/data"
    SEEDBOX_USER=lancelot
    SEEDBOX_HASH_TRANSMISSION='{0123456789abcdef'
    mkdir -p "$TRANSMISSION_STATE_DIR"
    transmission_settings_file() { echo "$file"; }
    diskguard_stopped() { return 1; }
    chown() { :; }
    systemctl() { echo "systemctl $*" >>"$WORK/umask-calls"; }
    for tested in "4.1.1+dfsg-1ubuntu1.1" "4.0.6-1" "3.00-2.1+deb12u1"; do
        dpkg-query() { echo "$tested"; }
        for start in '"002"' 0 2; do
            # every other setting already right (a first run puts them)
            rm -f "$file"
            seedbox_apply_transmission &>/dev/null || return 1
            jq --argjson u "$start" '.umask = $u' "$file" >"$file.x" && mv "$file.x" "$file"
            : >"$WORK/umask-calls"
            seedbox_apply_transmission &>/dev/null || return 1
            case $tested:$start in
                # already right: nothing written, Transmission not stopped
                4.*:'"002"' | *:2)
                    ! grep -q "stop transmission-daemon" "$WORK/umask-calls" && [[ $(jq -c .umask "$file") == "$start" ]]
                    ;;
                *) grep -q "stop transmission-daemon" "$WORK/umask-calls" && [[ $(jq -c .umask "$file") == 2 ]] ;;
            esac || {
                echo "$tested, umask $start: $(jq -c .umask "$file")"
                cat "$WORK/umask-calls"
                return 1
            }
        done
    done
    # the name of the setting in the log, when it was wrong
    grep -q "settings to change: umask" "$APP_LOG"
)

# Diagnostics: Transmission running with a umask that lets every account write
# its downloads (said only then)
doctor_transmission_umask_checked() (
    load
    transmission_process_umask() { echo 0002; }
    DOCTOR_WARNINGS=0
    doctor_transmission_umask >"$WORK/umask.out" 2>&1
    ((DOCTOR_WARNINGS == 0)) && [[ ! -s $WORK/umask.out ]] || return 1
    transmission_process_umask() { echo 0000; }
    doctor_transmission_umask >"$WORK/umask.out" 2>&1
    cat "$WORK/umask.out"
    ((DOCTOR_WARNINGS == 1)) && grep -q "writable by every account (umask 0000)" "$WORK/umask.out" || return 1
    # not running: nothing said
    transmission_process_umask() { :; }
    DOCTOR_WARNINGS=0
    doctor_transmission_umask >"$WORK/umask.out" 2>&1
    ((DOCTOR_WARNINGS == 0)) && [[ ! -s $WORK/umask.out ]]
)

# Nothing run from the folders where Transmission or the SFTP account write;
# its settings private again each time it starts or stops (it writes them
# then), by its own account
transmission_dropin_noexec_and_private() (
    load
    SEEDBOX_DATA_DIR=/srv/seedbox
    local dropin
    dropin=$(transmission_generate_dropin /etc/transmission-daemon/settings.json)
    grep -qxF "NoExecPaths=-/var/lib/transmission-daemon -/etc/transmission-daemon -/srv/seedbox" <<<"$dropin" \
        && grep -qxF "ExecStartPost=-/bin/chmod 600 /etc/transmission-daemon/settings.json" <<<"$dropin" \
        && grep -qxF "ExecStopPost=-/bin/chmod 600 /etc/transmission-daemon/settings.json" <<<"$dropin" || {
        echo "$dropin"
        return 1
    }
    # run by the account of Transmission (no « + »: never as root)
    ! grep -qE '^Exec(StartPost|StopPost)=[-@:!]*\+' <<<"$dropin"
)

# After each run, its settings in 600 and its folder closed to the others,
# changed by its own account
transmission_settings_made_private() (
    load
    install_without_owner
    local dir="$WORK/tr-private"
    rm -rf "$dir"
    mkdir -p "$dir/state" "$dir/dropin"
    printf '{"umask": 2}\n' >"$dir/settings.json"
    chmod 664 "$dir/settings.json"
    chmod 755 "$dir/state"
    TRANSMISSION_STATE_DIR="$dir/state"
    TRANSMISSION_DROPIN="$dir/dropin/seedtunnel.conf"
    SEEDBOX_DATA_DIR="$WORK/data"
    transmission_settings_file() { echo "$dir/settings.json"; }
    transmission_desired_settings() { echo '{"umask": 2}'; }
    transmission_knows_transports() { return 1; }
    transmission_knows_more_scripts() { return 1; }
    diskguard_stopped() { return 1; }
    systemctl() { :; }
    chown() { :; }
    : >"$WORK/runuser-calls"
    seedbox_apply_transmission >"$WORK/tr-private.out" 2>&1 || {
        cat "$WORK/tr-private.out"
        return 1
    }
    [[ $(stat -c %a "$dir/settings.json") == 600 && $(stat -c %a "$dir/state") == 750 ]] || {
        stat -c '%a %n' "$dir/settings.json" "$dir/state"
        return 1
    }
    (($(grep -cx "runuser $TRANSMISSION_USER" "$WORK/runuser-calls") == 2))
)

# Diagnostics: a program set to run, or settings readable by all, said
doctor_transmission_settings_checked() (
    load
    local dir="$WORK/tr-doctor"
    rm -rf "$dir"
    mkdir -p "$dir/state"
    chmod 750 "$dir/state"
    TRANSMISSION_STATE_DIR="$dir/state"
    transmission_settings_file() { echo "$dir/settings.json"; }
    printf '%s\n' '{"script-torrent-done-enabled": false, "script-torrent-added-enabled": false}' >"$dir/settings.json"
    chmod 600 "$dir/settings.json"
    DOCTOR_WARNINGS=0
    doctor_transmission_settings >"$WORK/trd.out" 2>&1
    ((DOCTOR_WARNINGS == 0)) && grep -q "Settings of Transmission private, no program run by it" "$WORK/trd.out" || {
        cat "$WORK/trd.out"
        return 1
    }
    chmod 664 "$dir/settings.json"
    DOCTOR_WARNINGS=0
    doctor_transmission_settings >"$WORK/trd.out" 2>&1
    ((DOCTOR_WARNINGS == 1)) && grep -q "can be read by every account" "$WORK/trd.out" || {
        cat "$WORK/trd.out"
        return 1
    }
    chmod 600 "$dir/settings.json"
    chmod 755 "$dir/state"
    DOCTOR_WARNINGS=0
    doctor_transmission_settings >"$WORK/trd.out" 2>&1
    ((DOCTOR_WARNINGS == 1)) || return 1
    printf '%s\n' '{"script-torrent-done-enabled": false, "script-torrent-added-enabled": true}' >"$dir/settings.json"
    DOCTOR_WARNINGS=0
    doctor_transmission_settings >"$WORK/trd.out" 2>&1
    cat "$WORK/trd.out"
    ((DOCTOR_WARNINGS == 1)) && grep -q "runs a program that seedtunnel did not set (script-torrent-added-enabled)" "$WORK/trd.out"
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

# --- SFTP: suspension checked, rule checked from everywhere, rename undone -

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
        && grep -q "bash $APP_STATE_DIR.before-restore-[0-9-]*.undo" "$WORK/restore2.out" \
        && grep -q "^mv -T -- $APP_STATE_DIR.before-restore-[0-9-]* $APP_STATE_DIR$" "$APP_STATE_DIR".before-restore-*.undo \
        && [[ $(cat "$APP_STATE_DIR".before-restore-*/vpn.conf) == "VPN_PORT=1194" ]]
)

# --- SFTP: « keys only » really checked, resume checked, keys in one go ---

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

# A file that is not there (or a folder): « File not found », never an
# unexpected error; nothing added
sftp_keys_import_missing_file() (
    sftp_keys_load missing
    : >"$SFTP_KEYS_DIR/lancelot"
    local source
    for source in "$WORK/nope.pub" "$WORK"; do
        if (sftp_keys_import "$source") &>"$WORK/keys.out"; then return 1; fi
        cat "$WORK/keys.out"
        grep -qF "File not found: $source" "$WORK/keys.out" && ! grep -qi "unexpected" "$WORK/keys.out" || return 1
    done
    [[ ! -s $SFTP_KEYS_DIR/lancelot ]]
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

# --- restore: no link, no code in the settings ------------------------

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
        CLIENT_PUBLIC_KEY="yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
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
    grep -q "is a link, a program or a special file" "$WORK/links.out"
)

# A path that goes up (« etc/seedtunnel/../../tmp/… ») is refused before
# anything is extracted, as a path out of the list (GNU tar would stop it too,
# but later and less clearly)
restore_refuses_going_up() (
    restore_archive_load up
    python3 - "$RESTORE_ROOT" "$WORK/up.tar.gz" <<'PY'
import io, sys, tarfile
root, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:gz") as tar:
    tar.add(root + "/etc/seedtunnel", arcname="etc/seedtunnel")
    data = b"x\n"
    info = tarfile.TarInfo("etc/seedtunnel/../../tmp/st-up")
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))
PY
    openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass pass:"a test passphrase" -in "$WORK/up.tar.gz" -out "$WORK/up.enc"
    if (restore_main "$WORK/up.enc") >"$WORK/up.out" 2>&1; then return 1; fi
    cat "$WORK/up.out"
    grep -q 'Archive refused: unexpected path "etc/seedtunnel/../../tmp/st-up"' "$WORK/up.out" && ! grep -q "Extracting the archive" "$WORK/up.out"
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

# Format of the settings: a backup made by a newer version (format 2) is
# refused first, with what to do, before anything changes; format 1 and a
# backup without it (before 1.0.4) go as far as the last question
restore_checks_settings_format() (
    restore_archive_load format
    local out
    # before 1.0.4: no format
    restore_archive_make format
    (restore_main "$WORK/format.enc") >"$WORK/format.out" 2>&1
    grep -q "The backup contains" "$WORK/format.out" || {
        cat "$WORK/format.out"
        return 1
    }
    echo 1 >"$RESTORE_ROOT/etc/seedtunnel/format"
    restore_archive_make format
    (restore_main "$WORK/format.enc") >"$WORK/format.out" 2>&1
    grep -q "The backup contains" "$WORK/format.out" || {
        cat "$WORK/format.out"
        return 1
    }
    # newer: refused, nothing asked, nothing left in the temporary folder
    echo 2 >"$RESTORE_ROOT/etc/seedtunnel/format"
    restore_archive_make format
    confirm() {
        echo asked
        return 1
    }
    if (restore_main "$WORK/format.enc") >"$WORK/format.out" 2>&1; then return 1; fi
    out=$(<"$WORK/format.out")
    [[ $out == *"made by a newer version of seedtunnel (settings format 2, this version reads up to 1)"* ]] \
        && [[ $out == *"seedtunnel update"* && $out != *"The backup contains"* && $out != *asked* ]] || {
        echo "$out"
        return 1
    }
    # not a number: refused as an unexpected value
    echo 'x;touch' >"$RESTORE_ROOT/etc/seedtunnel/format"
    restore_archive_make format
    if (restore_main "$WORK/format.enc") >"$WORK/format.out" 2>&1; then return 1; fi
    grep -q "unexpected value of format in etc/seedtunnel/format" "$WORK/format.out" || {
        cat "$WORK/format.out"
        return 1
    }
)

# Each backup holds the format of the settings; a server that only has it
# (with its language, packages, system) has nothing to keep aside
backup_notes_settings_format() (
    load
    APP_OS_ID=debian APP_OS_VERSION=13
    BACKUP_SYSTEM_FILE="$APP_STATE_DIR/system"
    BACKUP_FORMAT_FILE="$APP_STATE_DIR/format"
    rm -f "$BACKUP_FORMAT_FILE"
    sleep() { :; }
    backup_note_system
    [[ $(<"$BACKUP_FORMAT_FILE") == "$SETTINGS_FORMAT" && $(stat -c %a "$BACKUP_FORMAT_FILE") == 600 ]] || return 1
    [[ $(restore_bad_format "$WORK/no-such-folder") == "" ]] || return 1
    rm -rf "$WORK/fresh"
    mkdir -p "$WORK/fresh"
    echo 1 >"$WORK/fresh/format"
    echo debian >"$WORK/fresh/system"
    ! restore_has_settings "$WORK/fresh"
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

# --- backup: never a mix of two states, never an older backup replaced ----

# The fingerprints of the files written and the copies of the files changed by
# hand describe the server: never in a backup (restored, they made seedtunnel
# take its files for changed by hand)
backup_without_fingerprints() (
    backup_load
    mkdir -p "$APP_STATE_DIR/changed-by-hand"
    echo "VPN_PORT=51820" >"$APP_STATE_DIR/vpn.conf"
    echo "0123 /etc/nginx/sites-available/seedtunnel" >"$APP_STATE_DIR/written.sha256"
    echo "a copy" >"$APP_STATE_DIR/changed-by-hand/_etc_x.20261110-200000"
    # the last download of a backup describes this server too
    touch "$APP_STATE_DIR/backup.downloaded"
    backup_paths() { echo "${APP_STATE_DIR#/}"; }
    backup_write "$BACKUP_DIR/state.enc" </dev/null &>/dev/null || return 1
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass pass:"a test passphrase" \
        -in "$BACKUP_DIR/state.enc" | tar -tzf - >"$WORK/state.list" || return 1
    cat "$WORK/state.list"
    grep -q "/vpn.conf$" "$WORK/state.list" && ! grep -q "written.sha256\|changed-by-hand\|backup.downloaded" "$WORK/state.list"
)

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

# The first backup notes the system of the server in the settings: not taken
# for a setting changed while the archive is made (it was made twice)
backup_system_noted_without_second_archive() (
    backup_consistency_load
    BACKUP_DIR="$WORK/consistency/out"
    BACKUP_SYSTEM_FILE="$SETTINGS/system"
    APP_OS_ID=ubuntu
    APP_OS_VERSION=24.04
    backup_paths() { echo "${SETTINGS#/}"; }
    tar() {
        if [[ $1 == -czf ]]; then echo attempt >>"$WORK/attempts"; fi
        command tar "$@"
    }
    : >"$APP_LOG"
    backup_write "$BACKUP_DIR/first.enc" </dev/null &>/dev/null || return 1
    cat "$WORK/attempts" "$APP_LOG"
    (($(wc -l <"$WORK/attempts") == 1)) && ! grep -q "changed meanwhile" "$APP_LOG" \
        && [[ $(<"$SETTINGS/system") == "ubuntu 24.04" ]]
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
    went_back vpn_change_settings || return 1
    # empty port (the DNS has its own screen)
    answers "203.0.113.10" ""
    went_back vpn_change_settings || return 1
    # « no » to « Is that right? »
    confirm() { return 1; }
    answers "203.0.113.10" "51820"
    went_back vpn_change_settings || return 1
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
    went_back seedbox_change_credentials || return 1
    # « no » to the last question
    confirm() { return 1; }
    answers "lancelot"
    went_back seedbox_change_credentials || return 1
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
    answers "2" "not a key" "" "3" "5" "" "b"
    sftp_keys_menu >/dev/null 2>&1 || return 1
    back_nothing_done
)

unban_can_go_back() (
    back_load
    fail2ban_bans_print() { FAIL2BAN_LISTED=(203.0.113.7); }
    fail2ban_unban() { echo "unban $1" >>"$WORK/back-calls"; }
    # a wrong address, a number not in the list: asked again, then empty
    answers "x;y" "2" ""
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
    answers "1" "2" "b"
    backup_menu >/dev/null 2>&1 <<<$'\n\n' || return 1
    back_nothing_done && [[ ! -e $BACKUP_PASSPHRASE_FILE ]]
)

# A backup made from the menu: its download offered right away (« yes » by
# default); by command, the text with « seedtunnel backup share » as before
backup_from_menu_offers_link() (
    back_load
    local out
    BACKUP_DIR="$WORK/offer-backups"
    mkdir -p "$BACKUP_DIR"
    backup_require_something() { :; }
    backup_read_passphrase() { :; }
    backup_write() { : >"$1"; }
    backup_share_file() { echo "link $1" >>"$WORK/offer-calls"; }
    rm -f "$WORK/offer-calls"
    confirm() {
        echo "asked: $1"
        return 0
    }
    out=$(backup_menu_create 2>&1) || return 1
    [[ $out == *"Without the passphrase, it cannot be recovered."*"asked: Download it now (one-time link)?"* ]] || return 1
    [[ $(<"$WORK/offer-calls") == "link $BACKUP_DIR/"*.tar.gz.enc ]] || return 1
    # « no »: no link (a new name: the same second would be refused)
    rm -f "$WORK/offer-calls" "$BACKUP_DIR"/*
    confirm() { return 1; }
    backup_menu_create >/dev/null 2>&1 || return 1
    [[ ! -e $WORK/offer-calls ]] || return 1
    # by command: no question
    rm -f "$BACKUP_DIR"/*
    BACKUP_FROM_MENU=0
    confirm() {
        echo asked
        return 0
    }
    out=$(backup_main 2>&1) || return 1
    [[ $out != *asked* && $out == *"seedtunnel backup share"* && ! -e $WORK/offer-calls ]]
)

backup_menu_can_go_back() (
    back_load
    backup_auto_status() { :; }
    backup_list() { :; }
    backup_latest() { echo "$WORK/none.enc"; }
    restore_main() { echo "restore $1" >>"$WORK/back-calls"; }
    # restore: a file that does not exist asked again, then empty
    answers "3" "$WORK/none.enc" "" "b"
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
    # typed one after the other: nothing is waiting to be dropped
    (
        input_drop() { :; }
        # a wrong passphrase: asked again; then empty: back, nothing touched
        restore_main "$WORK/restore3.enc" >"$WORK/restore3.out" 2>&1 <<<$'wrong passphrase\n'
        rc=$?
        cat "$WORK/restore3.out"
        ((rc == 0 && WENT_BACK == 1)) && grep -q "Cannot decrypt" "$WORK/restore3.out" \
            && [[ $(<"$APP_STATE_DIR/vpn.conf") == "VPN_PORT=1194" && -z $BACKUP_TMP_DIR ]] || exit 1
        # 3 wrong passphrases, as sudo: stopped, nothing touched
        : >"$APP_LOG"
        if (restore_main "$WORK/restore3.enc") >"$WORK/restore3.out" 2>&1 <<<$'wrong 1\nwrong 2\nwrong 3\na test passphrase\n'; then exit 1; fi
        cat "$WORK/restore3.out"
        grep -q "Cannot decrypt after 3 tries" "$WORK/restore3.out" && (($(grep -c "Decrypting" "$APP_LOG") == 3)) \
            && [[ $(<"$APP_STATE_DIR/vpn.conf") == "VPN_PORT=1194" ]]
    ) || return 1
    # seen on a real server: a text of several lines pasted at the question is
    # one try, the rest is dropped (here, then the end of the input)
    : >"$APP_LOG"
    (restore_main "$WORK/restore3.enc") >"$WORK/restore3.out" 2>&1 <<<$'line 1 of a text\nline 2\nline 3\nline 4\n'
    rc=$?
    cat "$WORK/restore3.out"
    ((rc == 130)) && (($(grep -c "Decrypting" "$APP_LOG") == 1)) && [[ $(<"$APP_STATE_DIR/vpn.conf") == "VPN_PORT=1194" ]]
)

# --- reliability --------------------------------------------------------------

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

# Rules loaded by an older version (no protection of the clients): said, with
# the command that puts them in place
doctor_sees_clients_unprotected() (
    load
    VPN_PORT=51820
    systemctl() { return 0; }
    wg() { echo 51820; }
    sysctl() { echo 1; }
    vpn_count_clients() { echo 1; }
    vpn_connected_count() { echo 0; }
    default_interface() { echo ens3; }
    nft() { printf '%s\n' 'table ip seedtunnel {' '	chain postrouting {' '		ip saddr 10.8.0.0/24 oifname "ens3" masquerade' '	}' '}'; }
    DOCTOR_ERRORS=0 DOCTOR_WARNINGS=0
    doctor_vpn_nat >"$WORK/protect.out" 2>&1
    cat "$WORK/protect.out"
    ((DOCTOR_ERRORS == 0 && DOCTOR_WARNINGS == 1)) && grep -q "Clients of the VPN not protected" "$WORK/protect.out" || return 1
    # the rules of this version: fine
    nft() {
        printf '%s\n' 'table ip seedtunnel {' '	chain postrouting {' '		ip saddr 10.8.0.0/24 oifname "ens3" masquerade' '	}' \
            '	chain forward {' '		type filter hook forward priority filter; policy accept;' '		iifname "wg0" oifname "wg0" drop' \
            '		oifname "wg0" ct state established,related accept' '		oifname "wg0" ct status dnat accept' '		oifname "wg0" drop' '	}' '}'
    }
    DOCTOR_ERRORS=0 DOCTOR_WARNINGS=0
    doctor_vpn_nat >"$WORK/protect.out" 2>&1
    cat "$WORK/protect.out"
    ((DOCTOR_ERRORS == 0 && DOCTOR_WARNINGS == 0)) && grep -q "clients of the VPN protected" "$WORK/protect.out"
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

# The guard writes what it does to the log of seedtunnel too (only the
# journal had it): stopped, started again
diskguard_written_to_log() (
    load
    DISKGUARD_MARKER="$WORK/diskguard.logged"
    SEEDBOX_DATA_DIR=$WORK
    APP_LOG="$WORK/diskguard.log"
    rm -f "$DISKGUARD_MARKER" "$APP_LOG"
    seedbox_installed() { return 0; }
    logger() { :; }
    systemctl() { return 0; }
    disk_free_gb() { echo 1; }
    diskguard_check >"$WORK/dg-log.out" 2>&1 || return 1
    disk_free_gb() { echo 50; }
    diskguard_check >>"$WORK/dg-log.out" 2>&1 || return 1
    cat "$APP_LOG"
    grep -q "· Transmission stopped: disk almost full (1 GB free)." "$APP_LOG" \
        && grep -q "· Transmission started again: 50 GB free." "$APP_LOG"
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

# First run: a screen like the menus (header, keys, bottom line), in English
# even on a French system; Enter takes English; Q leaves without saving
language_first_screen() (
    load
    rm -f "$APP_LANG_FILE"
    SEEDTUNNEL_LANG=""
    INTERACTIVE=1
    UI_COLUMNS=80
    i18n_load fr
    language_first_run <<<'' >"$WORK/first.out" 2>&1 || return 1
    cat "$WORK/first.out"
    local text
    for text in "SeedTunnel" "v$APP_VERSION" "Welcome" "Choose your language" "[1] English" "[2] Français" \
        "[L] Language / Langue"; do
        grep -qF -- "$text" "$WORK/first.out" || {
            echo "missing: $text"
            return 1
        }
    done
    if grep -qE "seedbox privée|Bienvenue|Choisissez" "$WORK/first.out"; then return 1; fi
    # the bottom line: Q, in English (read shows it only to a terminal)
    [[ $UI_PROMPT == *"[Q] Quit"*"Your choice ›"* ]] || return 1
    [[ $(<"$APP_LANG_FILE") == en && $APP_LANG == en ]] || return 1
    rm -f "$APP_LANG_FILE"
    (language_first_run <<<'q') >/dev/null 2>&1
    [[ ! -e $APP_LANG_FILE ]]
)

language_asked_again() (
    load
    rm -f "$APP_LANG_FILE"
    SEEDTUNNEL_LANG=""
    INTERACTIVE=1
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

# A download refused by the limit is written to error.log with the whole
# request: below the level of that log, so that the token is never there
share_limit_not_in_error_log() (
    load
    local block
    block=$(share_generate_nginx "" | sed -n '/location \^~ \/share\/ {/,/^    }/p')
    grep -qxF '        limit_req zone=seedtunnel_share;' <<<"$block" \
        && grep -qxF '        limit_req_log_level info;' <<<"$block" && grep -qxF '        log_not_found off;' <<<"$block" || {
        echo "$block"
        return 1
    }
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
    # same address, new port
    answers "203.0.113.10" "51821"
    vpn_change_settings >"$WORK/port.out" 2>&1
    cat "$WORK/port.out" "$WORK/questions"
    # warned, asked (« no » by default), nothing applied
    grep -q "every client is disconnected" "$WORK/port.out" && grep -q "Change the port anyway?" "$WORK/questions" || return 1
    back_nothing_done || return 1
    # same port: not asked
    : >"$WORK/questions"
    VPN_PORT=51820
    answers "203.0.113.10" "51820"
    vpn_change_settings >"$WORK/port.out" 2>&1 || return 1
    ! grep -q "anyway" "$WORK/questions" && grep -q apply "$WORK/back-calls"
)

firewall_message_says_rule() (
    firewall_trial_load
    colors_init off
    UI_COLUMNS=80
    vpn_installed() { return 0; }
    # no new login: « yes » is refused, and the rule is said (before, and with
    # the refusal)
    journalctl() { :; }
    firewall_enable <<<"yes" >"$WORK/fw/out" 2>&1
    cat "$WORK/fw/out"
    grep -q "Through the public address of the server, it is always enough" "$WORK/fw/out" \
        && (($(grep -c "only if this window goes through the VPN too" "$WORK/fw/out") == 1)) \
        && (($(grep -c "it only counts if this window goes through the VPN too" "$WORK/fw/out") == 1))
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

# nginx never tells its version, port 80 included (the 443 already did not);
# one X-Frame-Options on the web interface: the one Transmission sends is
# hidden, nginx sends its own
nginx_hides_version_one_frame_header() (
    load
    SEEDBOX_DOMAIN=seedbox.example.org
    SEEDBOX_CERTIFICATE=letsencrypt
    local site generator servers tokens
    for generator in nginx_generate_site links_generate_site; do
        site=$($generator)
        servers=$(grep -c '^server {' <<<"$site")
        tokens=$(grep -c '^    server_tokens off;$' <<<"$site")
        ((servers == 2 && tokens == 2)) || {
            echo "$generator: $servers server(s), $tokens server_tokens off"
            return 1
        }
    done
    sed -n '/location \/transmission\/ {/,/^    }/p' <<<"$(nginx_generate_site)" | grep -qxF '        proxy_hide_header X-Frame-Options;' \
        && grep -qxF '    add_header X-Frame-Options SAMEORIGIN always;' <<<"$(nginx_generate_site)"
)

# The help of a command says « Utilisation » in French, never « Usage »
french_usage_word() (
    load
    ! grep -n '^fr: Usage :' "$ROOT/lang/fr.txt" && (($(grep -c '^en: Usage:' "$ROOT/lang/fr.txt") == $(grep -c '^fr: Utilisation :' "$ROOT/lang/fr.txt")))
)

# A subcommand given more arguments than it takes: refused before anything is
# done, as « seedtunnel doctor extra » already was; what they take still goes
# through (« vpn dns 9.9.9.9, 1.1.1.1 » arrives in two words)
cli_refuses_extra_arguments() (
    load
    local taken extra
    vpn_require_installed() { echo "called" >>"$WORK/extra-calls"; }
    seedbox_require_installed() { echo "called" >>"$WORK/extra-calls"; }
    firewall_status() { echo "called" >>"$WORK/extra-calls"; }
    backup_list() { echo "called" >>"$WORK/extra-calls"; }
    local line name
    local -a words
    : >"$WORK/extra-calls"
    # « the command as said in the message | what it takes | the extra »
    for line in "vpn list||extra" "vpn restart||x" "vpn add|a|b" "vpn uninstall||x" "seedbox bans||x" \
        "seedbox unban|192.0.2.1|x" "seedbox sftp-key list||x" "seedbox sftp-key add|file.pub|x" "seedbox restart||now" \
        "firewall status||x" "backup list||x" "backup delete|1|x" "backup auto on||x"; do
        IFS='|' read -r name taken extra <<<"$line"
        read -ra words <<<"$name $taken $extra"
        if ("${words[0]}_cli" "${words[@]:1}") >"$WORK/extra.out" 2>&1; then
            echo "accepted: $line"
            return 1
        fi
        grep -qF "Too many arguments for « seedtunnel $name »: $extra" "$WORK/extra.out" || {
            echo "$line:"
            cat "$WORK/extra.out"
            return 1
        }
    done
    # refused before anything is done
    [[ ! -s $WORK/extra-calls ]] || return 1
    # what they take: not refused for that
    vpn_set_dns() { echo "dns $1" >>"$WORK/extra-calls"; }
    sftp_keys_import() { echo "import $1" >>"$WORK/extra-calls"; }
    seedbox_apply_sftp() { :; }
    vpn_cli dns 9.9.9.9, 1.1.1.1 >"$WORK/extra.out" 2>&1 || return 1
    seedbox_cli sftp-key add file.pub >"$WORK/extra.out" 2>&1 || return 1
    firewall_cli status >"$WORK/extra.out" 2>&1 || return 1
    backup_cli list >"$WORK/extra.out" 2>&1 || return 1
    cat "$WORK/extra-calls"
    grep -qx "dns 9.9.9.9, 1.1.1.1" "$WORK/extra-calls" && grep -qx "import file.pub" "$WORK/extra-calls"
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
    # yesterday at noon: yesterday whatever the time of the test (« 25 hours
    # ago » was two days ago between midnight and one in the morning)
    touch -d 'yesterday 12:00' "$BACKUP_DOWNLOADED_MARK"
    doctor_backup >"$WORK/dates.out" 2>&1
    cat "$WORK/dates.out"
    grep -q "commencé hier" "$WORK/dates.out" && grep -q "la dernière : aujourd'hui" "$WORK/dates.out"
)

# --- a restore keeps the weekly backup working ----------------------------
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

# --- a restore checks the server first; firewall rules; report ---------------

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
    links_apply() { echo links >>"$RESTORE_STEPS"; }
    i18n_init() { i18n_load en; }
    RESTORE_MARKER="$APP_STATE_DIR.restore-unfinished"
    LINKS_CONF_FILE="$APP_STATE_DIR/links.conf"
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

# The SFTP account of this server (lancelot) is not the one of the backup
# (perceval): said before the question, renamed after it, before the seedbox
# is set up again. Another account of the system: refused first.
restore_renames_other_sftp_account() (
    restore_archive_load account
    printf 'SEEDBOX_USER=perceval-test-free\n' >"$RESTORE_ROOT/etc/seedtunnel/seedbox.conf"
    restore_archive_make account
    restore_record_steps account
    # this server: a VPN, and a seedbox with the account lancelot
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    seedbox_rename_account() { echo "rename $1 $2" >>"$RESTORE_STEPS"; }
    # the account lancelot exists on this server
    id() { [[ ${*: -1} == lancelot ]] || command id "$@"; }
    SEEDBOX_USER=lancelot
    printf 'SERVER=settings\n' >"$APP_STATE_DIR/server.conf"
    restore_main "$WORK/account.enc" >"$WORK/account.out" 2>&1 || {
        cat "$WORK/account.out"
        return 1
    }
    cat "$WORK/account.out" "$RESTORE_STEPS"
    grep -qF "The SFTP account lancelot takes back the name of the backup: perceval-test-free." "$WORK/account.out" \
        && [[ $(grep -n "takes back the name" "$WORK/account.out" | cut -d: -f1) -lt $(grep -n "Restore finished" "$WORK/account.out" | cut -d: -f1) ]] \
        && [[ $(sed -n 1p "$RESTORE_STEPS") == asked && $(sed -n 2p "$RESTORE_STEPS") == "rename lancelot perceval-test-free" ]] \
        && grep -qx seedbox "$RESTORE_STEPS" && [[ ! -e $RESTORE_MARKER ]] || return 1
    # the name of the backup is another account of this server (here, the one
    # running the tests): refused before the question, nothing changed
    restore_archive_load taken
    printf 'SEEDBOX_USER=%s\n' "$(id -un)" >"$RESTORE_ROOT/etc/seedtunnel/seedbox.conf"
    restore_archive_make taken
    restore_record_steps taken
    vpn_installed() { return 0; }
    seedbox_installed() { return 0; }
    SEEDBOX_USER=lancelot
    restore_refused_first taken "already exists on this server"
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
    SEEDBOX_USER=lancelot
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

# The same rules in the menu: a green frame that sums them up, the open ports,
# what every server allows, the other port pointed out, the ports forwarded to
# the clients in a table; off, or accepting everything: said in a frame
firewall_rules_screen_laid_out() (
    firewall_rules_load
    local out
    UI_COLUMNS=80
    ui_width
    out=$(firewall_rules_screen 2>&1)
    printf '%s\n' "$out"
    [[ $out == *"┌─ ● Firewall on"*"│ By default  everything coming in is refused"* ]] || return 1
    [[ $out == *"● Ports open on the server"*"SSH / SFTP     22/tcp"*"VPN WireGuard  51820/udp"*"Web site       80, 443/tcp"*"BitTorrent     60000 (TCP and UDP)"* ]] || return 1
    [[ $out == *"! Other port open: 8080/tcp"*"● Always allowed"*"Replies        to the connections already open"* ]] || return 1
    [[ $(tr -s ' \n' ' ' <<<"$out") == *"Network ping and ICMP (IPv4 and IPv6), IPv6 address from the provider (DHCPv6)"* ]] || return 1
    [[ $out == *"● Ports forwarded to the VPN clients"*"reachable from the Internet"*"PORT   CLIENT  ADDRESS"*"60002  laptop  10.8.0.3"* ]] || return 1
    # every rule found is said in the menu as for the commands
    [[ $out != *"✔ "* ]] || return 1
    RULES_POLICY=accept
    out=$(firewall_rules_screen 2>&1)
    [[ $out == *"┌─ ! Everything is accepted"*"seedtunnel firewall enable --yes"* ]] || return 1
    printf 'FIREWALL_ENABLED=0\n' >"$FIREWALL_CONF_FILE"
    out=$(firewall_rules_screen 2>&1)
    [[ $out == *"┌─ ! Firewall off"*"Nothing is refused"*"60002  laptop"* && $out != *"reachable from the Internet"* ]]
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
    SEEDBOX_USER=lancelot
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
$ usermod -aG debian-transmission lancelot
peer phone 10.8.0.4 port 60003, laptop 10.8.0.3 port 60002 (from 192.168.1.5)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBx7Lk7v9h2m lancelot@desktop
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
        lancelot laptop phone tablet watch desktop AAAAC3NzaC1lZDI1NTE5; do
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
    # the account lancelot, the client lancelot-laptop, a client named like a word
    printf 'CLIENT_NUMBER=4\n' >"$VPN_CLIENTS_DIR/lancelot-laptop.env"
    printf 'CLIENT_NUMBER=5\n' >"$VPN_CLIENTS_DIR/vpn.env"
    # the server is also 10.8.0.1 in its VPN: an address of every server
    ip() { printf '%s\n' '2: eth0    inet 203.0.113.10/24 scope global eth0' '3: wg0    inet 10.8.0.1/24 scope global wg0'; }
    printf '%s\n' 'peer lancelot-laptop of lancelot, the vpn listens on 10.8.0.1 and 203.0.113.10' >"$WORK/report.txt"
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

# -------------------------------------------------------------------------------

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

# --- interface (lib/ui.sh, tools/preview.sh) ----------------------------

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
    # (a pink background under the numbers was too much); the
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

# --- menus (lib/menu.sh, ui_action) ----------------------------------------

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
    VPN_DNS="9.9.9.9, 149.112.112.112"
    VPN_INTERFACE=wg0
    SEEDBOX_DOMAIN=seed.example.net
    SEEDBOX_DATA_DIR=$WORK
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_LETSENCRYPT_SERVER=production
    SEEDBOX_USER=lancelot
    SEEDBOX_SFTP_PASSWORD=yes
    UI_SERVER=vps-test
    UI_SYSTEM="Debian 13"
    UI_ADDRESS=203.0.113.10
    UI_ADDRESS_READ=1
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
    ufw_active() { return 1; }
    NFTABLES_CONF="$WORK/no-nftables.conf"
    firewall_enabled() { return 1; }
    home_firewall
    firewall_enabled() { return 0; }
    firewall_rules_missing_list() { :; }
    nft() { printf 'type filter hook input priority 0; policy drop;\n'; }
    home_firewall
    firewall_rules_missing_list() { printf 'SSH 22/tcp'; }
    home_firewall
    firewall_rules_missing_list() { :; }
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
    [[ ${UI_STATUS_LEVELS[*]} == "info warn bad" && ${UI_STATUS_STATES[0]} == "60%" && ${UI_STATUS_DETAILS[0]} == "40 GB free" ]] || {
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
    # the weekly backup on (with its passphrase): a recent backup is up to date
    echo x >"$BACKUP_PASSPHRASE_FILE"
    backup_auto_enabled() { return 0; }
    touch -d '2 days ago' "$WORK/home-backup.enc"
    home_backup
    # without the weekly backup, a recent one made by hand is « manual », in
    # yellow, and the details say why
    [[ ${UI_STATUS_LEVELS[*]} == "bad bad warn warn warn ok" && ${UI_STATUS_STATES[*]} == "failed failed none yet manual old recent" ]] || {
        echo "${UI_STATUS_LEVELS[*]} / ${UI_STATUS_STATES[*]}"
        return 1
    }
    [[ ${UI_STATUS_DETAILS[3]} == "last backup 2 days ago · weekly backup off" && ${UI_STATUS_SHORT[3]} == "2 days ago" ]] || return 1
    [[ ${UI_STATUS_DETAILS[4]} == "last backup 9 days ago · weekly backup off" && ${UI_STATUS_DETAILS[5]} == "last backup 2 days ago" ]]
)

# The words of the blocks fit in them (9 characters), in English and in French
home_state_words_fit_blocks() (
    load
    local language word
    for language in en fr; do
        i18n_load "$language"
        for word in missing running stopped absent halted problem on off failed 'none yet' recent old manual; do
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

# -----------------------------------------------------------------------------------

# The log is cut every month (it used to grow without end), from the
# installation and from « apply » (so after an update too). « su root root »:
# without it, logrotate skips it on Ubuntu (/var/log writable by syslog)
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
    for word in 'su root root' monthly 'rotate 6' compress 'create 0600 root root' missingok; do
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
    : >"$APP_LOG"
    (update_back) &>"$WORK/back.out" || {
        cat "$WORK/back.out"
        return 1
    }
    grep -q 'APP_VERSION="2.0.0"' "$APP_DIR/lib/common.sh" && [[ $(<"$WORK/app/applied") == old ]] \
        && [[ ! -e $APP_DIR.old && ! -e $APP_DIR.previous ]] || return 1
    # written in the log, which said nothing of it
    grep -qE '^=== [0-9-]+ [0-9:]+ · Back to version 2\.0\.0 \(version 2\.1\.0 removed\)$' "$APP_LOG" || {
        cat "$APP_LOG"
        return 1
    }
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
    : >"$APP_LOG"
    if (update_back) &>"$WORK/back.out"; then return 1; fi
    grep -q "Going back cancelled" "$WORK/back.out" && ! grep -q "version 2.1.0 removed" "$APP_LOG" || {
        cat "$WORK/back.out"
        return 1
    }
    grep -q 'APP_VERSION="2.1.0"' "$APP_DIR/lib/common.sh" && grep -q 'APP_VERSION="2.0.0"' "$APP_DIR.old/lib/common.sh" \
        && [[ $(tr '\n' ' ' <"$WORK/app/applied") == "old new " && ! -e $APP_DIR.previous ]]
)

# The end of an update is written in the log by the new version, at the end of
# its « apply » (the version replaced, older, waits in APP_DIR.previous): the
# version replaced, which runs the update, may not know how. Not for a version
# that is not older, nor without one.
update_logs_the_version_installed() (
    load
    APP_DIR="$WORK/app/seedtunnel"
    rm -rf "$WORK/app"
    APP_VERSION=2.1.0
    : >"$APP_LOG"
    update_log_installed
    fake_version_make "$APP_DIR.previous" 2.2.0 newer
    update_log_installed
    [[ ! -s $APP_LOG ]] || {
        cat "$APP_LOG"
        return 1
    }
    rm -rf "$APP_DIR.previous"
    fake_version_make "$APP_DIR.previous" 2.0.0 old
    update_log_installed
    grep -qE '^=== [0-9-]+ [0-9:]+ · Update: 2\.0\.0 → 2\.1\.0 installed$' "$APP_LOG" || {
        cat "$APP_LOG"
        return 1
    }
    # in French on a French server
    : >"$APP_LOG"
    APP_DIR=$ROOT i18n_load fr
    update_log_installed
    grep -qE '· Mise à jour : 2\.0\.0 → 2\.1\.0 installée$' "$APP_LOG" || return 1
    # at the very end of « apply », once everything worked
    [[ $(declare -f apply_main | grep -vx ' *}' | tail -n 1) == *update_log_installed* ]]
)

# An update by git that worked: written in the log too
update_git_logs_the_version_installed() (
    load
    UPDATE_NEW_STATUS=0
    update_git_make
    git() {
        if fetch_stub "$@"; then return 0; fi
        command git "$@"
    }
    : >"$APP_LOG"
    (update_from_git) &>"$WORK/update.out" || {
        cat "$WORK/update.out"
        return 1
    }
    grep -qE '^=== [0-9-]+ [0-9:]+ · Update: 1\.0\.0 → 9\.9\.9 installed$' "$APP_LOG" || {
        cat "$APP_LOG"
        return 1
    }
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

# --- the clients connect, but another program blocks their traffic --------

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

# What is wrong around the firewall, for the home screen and the screen
# Firewall: Docker that blocks the clients (red, with the commands), rules for
# Docker that a restart removes (yellow), another program (red, its table),
# nftables that empties the rules at boot (yellow), ufw (red)
firewall_findings_cases() (
    load
    colors_init off
    UI_COLUMNS=80
    ui_width
    INTERACTIVE=1
    default_interface() { echo ens3; }
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    ufw_active() { return 1; }
    firewall_enabled() { return 0; }
    firewall_summary() { echo "SSH (22/tcp), VPN (51820/udp)"; }
    firewall_rules_missing_list() { :; }
    systemctl() { return 1; }
    NFTABLES_CONF="$WORK/nftables.conf"
    rm -f "$NFTABLES_CONF"
    DOCKER_DAEMON_CONFIG="$WORK/daemon-findings.json"
    rm -f "$DOCKER_DAEMON_CONFIG"
    nft() { if [[ $* == "list ruleset" ]]; then docker_ruleset; else printf 'type filter hook input priority 0; policy drop;\n'; fi; }
    # nothing wrong: green, nothing said
    DOCKER_USER_RULES=yes
    printf '{ "ip-forward-no-drop": true }\n' >"$DOCKER_DAEMON_CONFIG"
    firewall_findings
    ((${#FW_LEVELS[@]} == 0)) || return 1
    ui_status_reset
    home_firewall
    [[ ${UI_STATUS_LEVELS[*]} == ok && ${UI_STATUS_STATES[*]} == on ]] || return 1
    # Docker blocks: red, the commands of this server under the frame
    DOCKER_USER_RULES=no
    rm -f "$DOCKER_DAEMON_CONFIG"
    firewall_status >"$WORK/findings.out" 2>&1
    cat "$WORK/findings.out"
    grep -q "✔ Firewall on — open: SSH (22/tcp), VPN (51820/udp)" "$WORK/findings.out" \
        && grep -q "┌─ ! Docker blocks the VPN ─" "$WORK/findings.out" \
        && grep -q "Docker 28 or later" "$WORK/findings.out" \
        && grep -qxF '    iptables -I DOCKER-USER -i wg0 -o ens3 -j ACCEPT' "$WORK/findings.out" \
        && grep -qxF '    iptables -I DOCKER-USER -i ens3 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED,DNAT -j ACCEPT' "$WORK/findings.out" || return 1
    ui_status_reset
    home_firewall
    [[ ${UI_STATUS_LEVELS[*]} == bad && ${UI_STATUS_STATES[*]} == problem && ${UI_STATUS_DETAILS[*]} == "firewall: Docker blocks the VPN" && ${UI_STATUS_SHORT[*]} == "Docker blocks the VPN" ]] || {
        echo "${UI_STATUS_LEVELS[*]} / ${UI_STATUS_STATES[*]} / ${UI_STATUS_DETAILS[*]}"
        return 1
    }
    # let through by rules typed by hand: yellow « warning »
    DOCKER_USER_RULES=yes
    ui_status_reset
    home_firewall
    [[ ${UI_STATUS_LEVELS[*]} == warn && ${UI_STATUS_STATES[*]} == warning && ${UI_STATUS_DETAILS[*]} == "firewall: rules for Docker temporary" ]] || return 1
    # the firewall of seedtunnel off: yellow « off », with the reason
    firewall_enabled() { return 1; }
    ui_status_reset
    home_firewall
    [[ ${UI_STATUS_LEVELS[*]} == warn && ${UI_STATUS_STATES[*]} == off && ${UI_STATUS_DETAILS[*]} == "firewall: rules for Docker temporary" ]] || return 1
    firewall_enabled() { return 0; }
    # another program: red, its table named
    nft() { if [[ $* == "list ruleset" ]]; then printf '%s\n' 'table inet other {' '	chain forward {' '		type filter hook forward priority 0; policy drop;' '	}' '}'; else printf 'type filter hook input priority 0; policy drop;\n'; fi; }
    firewall_status >"$WORK/findings.out" 2>&1
    grep -q "┌─ ! Another program blocks the VPN ─" "$WORK/findings.out" && grep -q "(table inet other)" "$WORK/findings.out" || {
        cat "$WORK/findings.out"
        return 1
    }
    # nftables that empties the rules at boot, and ufw on: both said, the
    # worst on the home screen
    nft() { printf 'type filter hook input priority 0; policy drop;\n'; }
    systemctl() { [[ $* == "is-enabled --quiet nftables.service" ]]; }
    printf 'flush ruleset\n' >"$NFTABLES_CONF"
    ufw_active() { return 0; }
    firewall_findings
    [[ ${FW_LEVELS[*]} == "bad warn" && ${FW_TITLES[0]} == "ufw is on" && ${FW_TITLES[1]} == "nftables empties the rules" ]] || {
        echo "${FW_LEVELS[*]} / ${FW_TITLES[*]}"
        return 1
    }
    ui_status_reset
    home_firewall
    [[ ${UI_STATUS_LEVELS[*]} == bad && ${UI_STATUS_DETAILS[*]} == "firewall: ufw is on" ]] || return 1
    # the SSH port missing from the rules: red, said as such
    ufw_active() { return 1; }
    rm -f "$NFTABLES_CONF"
    firewall_rules_missing_list() { printf 'SSH 2222/tcp'; }
    firewall_status >"$WORK/findings.out" 2>&1
    grep -q "┌─ ! The SSH port is closed" "$WORK/findings.out" && grep -q "(SSH 2222/tcp)" "$WORK/findings.out" \
        && grep -q "\[1\] Enable / update the firewall opens it (on trial)." "$WORK/findings.out" || {
        cat "$WORK/findings.out"
        return 1
    }
    # for the command: lines, and the command instead of the menu
    INTERACTIVE=0
    firewall_status >"$WORK/findings.out" 2>&1
    cat "$WORK/findings.out"
    grep -qx "✘ The SSH port is closed" "$WORK/findings.out" && grep -q "seedtunnel firewall enable opens it" "$WORK/findings.out" \
        && ! grep -q "┌─" "$WORK/findings.out"
)

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

# --- found by the stress test on a real server ------------------------------

# Rules of the firewall removed (another program empties nftables, a table
# removed by hand): their file is the same, « apply » loads them again
firewall_rules_put_back_when_gone() (
    firewall_trial_load
    firewall_generate_rules() { echo "the rules"; }
    echo "the rules" >"$FIREWALL_RULES"
    FIREWALL_ENABLED=1
    state_write "$FIREWALL_CONF_FILE" FIREWALL_ENABLED
    systemctl() { return 0; }
    POLICY=""
    nft() {
        if [[ $1 == list ]]; then
            [[ -n $POLICY ]] || return 1
            printf '%s\n' 'table inet seedtunnel_fw {' '	chain input {' "		type filter hook input priority filter; policy $POLICY;" '	}' '}'
        else
            echo "nft $*" >>"$WORK/fw/calls"
        fi
    }
    # not loaded: loaded again
    firewall_refresh >"$WORK/fw/out" 2>&1 || return 1
    grep -q "^nft -f" "$WORK/fw/calls" || {
        cat "$WORK/fw/out"
        return 1
    }
    # loaded, but refusing nothing by default: loaded again
    : >"$WORK/fw/calls"
    POLICY=accept
    firewall_refresh >"$WORK/fw/out" 2>&1 || return 1
    grep -q "^nft -f" "$WORK/fw/calls" || return 1
    # in force: nothing to do (nor anything the settings need missing)
    : >"$WORK/fw/calls"
    POLICY=drop
    firewall_rules_missing() { :; }
    firewall_refresh >"$WORK/fw/out" 2>&1 || return 1
    [[ ! -s $WORK/fw/calls ]]
)

# nginx and fail2ban taken out of the boot: « apply » puts them back, and the
# diagnostics warn (they would not come back after a restart of the server)
services_put_back_at_boot() (
    load
    mkdir -p "$WORK/boot"
    : >"$WORK/boot/calls"
    NGINX_SITE="$WORK/boot/site"
    NGINX_SITE_LINK="$WORK/boot/link"
    NGINX_DEFAULT_SITE="$WORK/boot/default"
    ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
    write_if_changed() { return 1; }
    touch() { :; }
    systemctl() {
        echo "systemctl $*" >>"$WORK/boot/calls"
        [[ $1 != is-enabled ]]
    }
    seedbox_apply_nginx >/dev/null 2>&1 || return 1
    seedbox_apply_fail2ban >/dev/null 2>&1 || return 1
    grep -qx "systemctl enable --now nginx" "$WORK/boot/calls" && grep -qx "systemctl enable --now fail2ban" "$WORK/boot/calls" || {
        cat "$WORK/boot/calls"
        return 1
    }
    # diagnostics: running but not at boot → warning; SSH is not checked there
    colors_init off
    DOCTOR_WARNINGS=0
    doctor_service nginx 'nginx' boot >"$WORK/boot/out"
    doctor_service ssh.service 'SSH / SFTP' >>"$WORK/boot/out"
    cat "$WORK/boot/out"
    ((DOCTOR_WARNINGS == 1)) && grep -q "nginx: running, but not started at boot" "$WORK/boot/out" || return 1
    systemctl() { return 0; }
    DOCTOR_WARNINGS=0
    doctor_service nginx 'nginx' boot >/dev/null
    ((DOCTOR_WARNINGS == 0)) && declare -f doctor_seedbox | grep -q "nginx 'nginx' boot" \
        && declare -f doctor_seedbox | grep -q "fail2ban 'fail2ban' boot"
)

# The file refused is named as in the archive, not in a temporary folder
restore_names_refused_file_as_in_archive() (
    restore_archive_load named
    printf 'CLIENT_NUMBER=2;touch\n' >>"$RESTORE_ROOT/etc/seedtunnel/vpn/clients/laptop.env"
    restore_archive_make named
    if (restore_main "$WORK/named.enc") >"$WORK/named.out" 2>&1; then return 1; fi
    cat "$WORK/named.out"
    grep -q "refused: etc/seedtunnel/vpn/clients/laptop.env holds" "$WORK/named.out"
)

# « 1 clients connectés sur 1 »: the French sentence is right for any number
home_clients_in_french() (
    load
    i18n_load fr
    ui_status_reset
    vpn_installed() { return 0; }
    vpn_load() { :; }
    systemctl() { return 0; }
    vpn_connected_count() { echo 1; }
    vpn_count_clients() { echo 1; }
    home_vpn
    [[ ${UI_STATUS_DETAILS[0]} == "clients connectés : 1 sur 1" ]] || {
        echo "${UI_STATUS_DETAILS[0]}"
        return 1
    }
)

# In the sentences, a space between the number and its unit (« 34 Go »)
sizes_with_a_space() (
    load
    [[ $(human_size_spaced 38654705664) == "36 GB" && $(human_size_spaced 512) == "512 B" ]] || return 1
    [[ $(human_size 38654705664) == "36GB" ]] || return 1
    i18n_load fr
    [[ $(human_size_spaced 1610612736) == "1.5 Go" || $(human_size_spaced 1610612736) == "1,5 Go" ]]
)

# Web interface: the style of seedtunnel added to the page of Transmission 4
# (Debian 13); on Transmission 3 (Debian 12, another page), see
# web_interface_style_transmission3
web_interface_style() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seed.example.net
    TRANSMISSION_RPC_PORT=9091
    VERSION="4.1.0~beta2+dfsg-3+deb13u1"
    dpkg-query() { echo "$VERSION"; }
    nginx_generate_site >"$WORK/site4"
    grep -qF "sub_filter '</head>' '<link href=\"/seedtunnel/transmission-theme.css\" rel=\"stylesheet\" /></head>';" "$WORK/site4" \
        && grep -qF "alias $ROOT/web/transmission-theme.css;" "$WORK/site4" \
        && grep -qF 'proxy_set_header Accept-Encoding "";' "$WORK/site4" \
        && grep -qF "<title>SeedTunnel · Transmission</title>" "$WORK/site4" || {
        cat "$WORK/site4"
        return 1
    }
    VERSION="1:4.0.6-1"
    nginx_generate_site | grep -q "transmission-theme.css" || return 1
    VERSION="5.0.0-1"
    nginx_generate_site | grep -q "transmission-theme.css" || return 1
    # the style sheet is in the published archive and changes the colors of
    # Transmission 4
    grep -q -- "--color-bg-primary" "$ROOT/web/transmission-theme.css" \
        && ! grep -qE '^web( |/)' "$ROOT/.gitattributes"
)

# Web interface: the colors of the bars are plain colors. Transmission 4.0
# (Ubuntu 24.04) puts them inside its own gradient: with a gradient there, the
# bar of a download stayed empty. The pink gradient is kept for 4.1 and later,
# in a rule of its own.
web_interface_bars_plain_colors() (
    local theme=$ROOT/web/transmission-theme.css
    grep -q -- "--color-progressbar-leech:" "$theme" || return 1
    ! grep -qE -- "--color-progressbar-[a-z0-9-]+:[^;]*gradient" "$theme" || {
        grep -nE -- "--color-progressbar-[a-z0-9-]+:[^;]*gradient" "$theme"
        return 1
    }
    grep -qF ".torrent-progress-bar.leech:not(.paused):not(.queued)::before" "$theme"
)

# --- what the screens and the log say -------------------------------------

# Menu of the seedbox: the line of the services shows the 3 names and their
# states, never cut. In 80 columns, « transmission en marche · nginx en marche ·
# fail2ban en marche » was cut by « … », and the state of fail2ban was lost.
services_line_never_cut() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_USER=seedbox
    SEEDBOX_DATA_DIR=$WORK
    seedbox_certificate_label() { printf 'ok, 86 days'; }
    sftp_password_state() { printf 'refused'; }
    disk_free_text() { printf '29 GB free of 39 GB'; }
    declare -A STATE
    systemctl() {
        local state=${STATE[${*: -1}]-active}
        case $1 in
            is-active) [[ $state == active ]] ;;
            cat) [[ $state != missing ]] ;;
        esac
    }
    FULL=0
    diskguard_stopped() { ((FULL)); }
    local language colors case out line width expected
    for language in en fr; do
        i18n_load "$language"
        for colors in 1 0; do
            if ((colors)); then C_GREEN=$'\e[1;32m' C_RED=$'\e[1;31m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'; else C_GREEN="" C_RED="" C_DIM="" C_RESET=""; fi
            for case in all nginx-stopped fail2ban-missing disk-full narrow; do
                STATE=() FULL=0 UI_WIDTH=79 SEEDBOX_DOMAIN=vps-1234abcd.vps.ovh.ca
                case $case in
                    all) expected="Transmission ● · nginx ● · fail2ban ●" ;;
                    nginx-stopped) STATE[nginx]=inactive expected="nginx ● $(t 'stopped') · fail2ban ●" ;;
                    fail2ban-missing) STATE[fail2ban]=missing expected="nginx ● · fail2ban ● $(t 'missing')" ;;
                    disk-full) FULL=1 expected="Transmission ● $(t 'stopped: disk almost full')" ;;
                    narrow) UI_WIDTH=50 SEEDBOX_DOMAIN=seed.example.net expected="fail2ban ●" ;;
                esac
                out=$(seedbox_menu_fields | sed 's/\x1b\[[0-9;]*m//g')
                width=0
                while IFS= read -r line; do
                    ui_len "$line"
                    if ((UI_LEN > UI_WIDTH)); then width=$UI_LEN; fi
                done <<<"$out"
                if [[ $out == *…* || $out != *"$expected"* || $out != *Transmission* || $out != *nginx* || $out != *fail2ban* ]] || ((width)); then
                    printf '%s, colors %s, %s:\n%s\n' "$language" "$colors" "$case" "$out"
                    return 1
                fi
                # a service that does not run never looks fine: its dot has a word
                if [[ $case == nginx-stopped && $out == *"nginx ● ·"* ]] || [[ $case == fail2ban-missing && $out == *"fail2ban ●" ]]; then return 1; fi
                # with colors: green dot when it runs, red when it does not
                if ((colors)); then
                    out=$(seedbox_menu_fields)
                    case $case in
                        all) [[ $out == *"nginx $C_GREEN●$C_RESET"* ]] || return 1 ;;
                        nginx-stopped) [[ $out == *"nginx $C_RED● "* ]] || return 1 ;;
                    esac
                fi
                if [[ $out == *OK* ]]; then return 1; fi
            done
        done
    done
)

# « today », « yesterday »: days of the calendar, not slices of 24 hours. At
# 09:00, a backup of yesterday 22:00 was « today ».
ages_in_calendar_days() (
    load
    touch -d "$(date +%F) 00:00:01" "$WORK/today"
    touch -d "$(date -d yesterday +%F) 23:59:59" "$WORK/yesterday"
    touch -d "$(date -d '3 days ago' +%F) 23:59:59" "$WORK/three-days"
    [[ $(file_age_days "$WORK/today") == 0 && $(file_age_days "$WORK/yesterday") == 1 ]] || return 1
    [[ $(file_age_days "$WORK/three-days") == 3 && -z $(file_age_days "$WORK/missing") ]]
)

# Free space rounded down, as in the diagnostic: the home screen said « 30 GB
# free » when the diagnostic said « 29 GB » (29.3 GB)
free_space_rounded_down() (
    load
    [[ $(human_size_spaced $((29 * 1073741824 + 300 * 1048576))) == "29 GB" ]] \
        && [[ $(human_size 38654705664) == "36GB" && $(human_size 512) == "512B" ]]
)

# The titles of the log are in the language of the messages (« kernel network
# hardening » in a French log), and the report still finds the names of the
# VPN clients in the titles of the download links, whatever their language
log_titles_translated() (
    load
    i18n_load fr
    log_title 'Kernel network hardening'
    log_title 'Download link for %s' laptop.conf
    grep -qx "=== .* · Durcissement réseau du noyau" "$APP_LOG" \
        && grep -qx "=== .* · Lien de téléchargement pour laptop.conf" "$APP_LOG" || return 1
    # no title left in English, written by hand in the code
    if grep -n "=== %(%F %T)T · [a-zA-Z]" "$ROOT"/lib/*.sh; then return 1; fi
    report_load
    printf '=== 2026-11-10 10:00:00 · Lien de téléchargement pour tablet.conf\n=== 2026-11-10 10:01:00 · Download link for watch.conf\n' >>"$WORK/report.txt"
    report_anonymize "$WORK/report.txt"
    if grep -qw -e tablet -e watch "$WORK/report.txt"; then
        cat "$WORK/report.txt"
        return 1
    fi
)

# Restoring with a wrong passphrase: « bad decrypt » under a title of its own,
# not under the step before
decrypt_errors_under_their_title() (
    load
    OPT_PASSPHRASE_FILE=$WORK/passphrase
    printf 'wrong passphrase\n' >"$OPT_PASSPHRASE_FILE"
    # encrypted with another passphrase: « bad decrypt », as on a real server.
    # A fixed salt: with a random one, about 1 time in 256 the wrong key
    # happens to give a valid end of block, and gzip fails instead
    {
        printf 'Salted__\001\002\003\004\005\006\007\010'
        printf 'archive' | openssl enc -aes-256-cbc -pbkdf2 -iter 1000 -S 0102030405060708 -pass pass:right
    } >"$WORK/seedtunnel-host-20261110.tar.gz.enc"
    banner() { :; }
    restore_unfinished() { :; }
    secret_file_check() { :; }
    printf '\n=== 2026-11-10 10:00:00 · Download link for laptop.conf\n' >"$APP_LOG"
    if (restore_main "$WORK/seedtunnel-host-20261110.tar.gz.enc") &>/dev/null; then return 1; fi
    # the last title before the error of openssl
    awk '/^=== / { title = $0 } /bad decrypt/ { print title; exit }' "$APP_LOG" | grep -q "· Decrypting seedtunnel-host-20261110.tar.gz.enc$" || {
        cat "$APP_LOG"
        return 1
    }
)

# --- files changed by hand, site « default » of nginx -------------------------

# A file written by seedtunnel, then changed by hand, was replaced at the next
# apply without a word. Now: a copy is kept (root only), it is said, and the
# diagnostic warns before. Nothing is said when nothing is known (first time).
changed_by_hand_copy_kept() (
    load
    generate() { printf 'version %s\n' "$V"; }
    doctor_warn() {
        printf 'WARN '
        t "$@"
        echo
    }
    local out copy
    # a file there before seedtunnel kept fingerprints: nothing said
    printf 'old\n' >"$WORK/old.conf"
    V=1 out=$(write_if_changed "$WORK/old.conf" 600 "$ME" generate 2>&1)
    [[ -z $out && ! -d $APP_STATE_DIR/changed-by-hand ]] || return 1
    # seedtunnel changing its own file: nothing said
    V=1 write_if_changed "$WORK/wg0.conf" 600 "$ME" generate
    V=2 out=$(write_if_changed "$WORK/wg0.conf" 600 "$ME" generate 2>&1)
    [[ -z $out && -z $(doctor_changed_by_hand) ]] || return 1
    # changed by hand: the diagnostic warns, the next write keeps a copy
    printf 'PostUp = my rule\n' >>"$WORK/wg0.conf"
    [[ $(doctor_changed_by_hand) == "WARN $WORK/wg0.conf changed by hand"* ]] || return 1
    V=3 out=$(write_if_changed "$WORK/wg0.conf" 600 "$ME" generate 2>&1)
    copy=$(ls "$APP_STATE_DIR"/changed-by-hand/* 2>/dev/null)
    [[ $out == *"$WORK/wg0.conf was changed by hand"* && $out == *"$copy"* && -n $copy ]] || {
        echo "$out"
        return 1
    }
    [[ $(<"$copy") == $'version 2\nPostUp = my rule' && $(<"$WORK/wg0.conf") == "version 3" ]] || return 1
    [[ $(stat -c %a "$copy") == 600 && $(stat -c %a "$APP_STATE_DIR/changed-by-hand") == 700 ]] || return 1
    grep -q "· Changed by hand: $WORK/wg0.conf" "$APP_LOG" || return 1
    # put back: nothing more said
    V=4 out=$(write_if_changed "$WORK/wg0.conf" 600 "$ME" generate 2>&1)
    [[ -z $out && -z $(doctor_changed_by_hand) ]]
)

# « apply » writes nothing that did not change: a state file and the list of
# fingerprints keep their date when their content is the same (they did not,
# on Ubuntu 26.04: vpn.conf, seedbox.conf, written.sha256)
same_content_not_rewritten() (
    load
    APP_STATE_DIR="$WORK/same-state"
    rm -rf "$APP_STATE_DIR"
    mkdir -p "$APP_STATE_DIR"
    local file="$APP_STATE_DIR/test.conf" list A=1 B="two words"
    state_write "$file" A B
    chmod 644 "$file"
    touch -d '2020-01-01 00:00' "$file"
    state_write "$file" A B
    [[ $(stat -c '%Y %a' "$file") == "$(date -d '2020-01-01 00:00' +%s) 600" ]] || {
        stat -c '%y %a' "$file"
        return 1
    }
    B="other"
    state_write "$file" A B
    grep -qx "B=other" "$file" && [[ $(stat -c %Y "$file") != "$(date -d '2020-01-01 00:00' +%s)" ]] || return 1
    # the list of fingerprints
    generate() { echo "$1"; }
    write_if_changed "$WORK/same-b.conf" 600 "$ME" generate b
    write_if_changed "$WORK/same-a.conf" 600 "$ME" generate a
    list=$(written_list)
    touch -d '2020-01-01 00:00' "$list"
    write_if_changed "$WORK/same-b.conf" 600 "$ME" generate b || true
    write_if_changed "$WORK/same-a.conf" 600 "$ME" generate a || true
    [[ $(stat -c %Y "$list") == "$(date -d '2020-01-01 00:00' +%s)" ]] || {
        cat "$list"
        return 1
    }
    write_if_changed "$WORK/same-a.conf" 600 "$ME" generate changed
    [[ $(stat -c %Y "$list") != "$(date -d '2020-01-01 00:00' +%s)" ]]
)

# A file deleted since it was written (removal of the seedbox…) leaves the
# list of fingerprints at the next write; the others stay, a path with a
# space included
written_list_drops_deleted_files() (
    load
    APP_STATE_DIR="$WORK/written-state"
    rm -rf "$APP_STATE_DIR"
    mkdir -p "$APP_STATE_DIR"
    generate() { echo "$1"; }
    mkdir -p "$WORK/written dir"
    write_if_changed "$WORK/written dir/kept.conf" 600 "$ME" generate kept
    write_if_changed "$WORK/written-gone.conf" 600 "$ME" generate gone
    rm "$WORK/written-gone.conf"
    write_if_changed "$WORK/written-new.conf" 600 "$ME" generate new
    cat "$(written_list)"
    grep -qF " $WORK/written dir/kept.conf" "$(written_list)" && grep -qF " $WORK/written-new.conf" "$(written_list)" \
        && ! grep -q "written-gone" "$(written_list)" && (($(wc -l <"$(written_list)") == 2))
)

# After a restore, the fingerprints are those of the server backed up; after
# a return to an older version, files are rewritten without them: forgotten
# in both cases, so that nothing is taken for a change by hand. sshd refusing
# the new file: the version put back is the one of seedtunnel.
fingerprints_forgotten_when_unknown() (
    load
    generate() { echo new; }
    write_if_changed "$WORK/file" 600 "$ME" generate
    [[ -f $(written_list) ]] || return 1
    written_forget
    [[ ! -e $(written_list) ]] || return 1
    declare -f restore_main | grep -q written_forget \
        && declare -f update_back | grep -q written_forget \
        && grep -A2 'mv -f "$SSHD_SEEDBOX_CONF.previous" "$SSHD_SEEDBOX_CONF"' "$ROOT/lib/seedbox.sh" | grep -q 'written_remember "$SSHD_SEEDBOX_CONF"'
)

# The site « default » of nginx was deleted at every apply, even when the
# administrator had changed it. Now only the one of the package is turned off.
nginx_default_site_kept_if_changed() (
    load
    NGINX_DEFAULT_SOURCE=$WORK/sites-available/default
    NGINX_DEFAULT_SITE=$WORK/sites-enabled/default
    mkdir -p "$WORK/sites-available" "$WORK/sites-enabled"
    printf 'server { listen 80 default_server; }\n' >"$NGINX_DEFAULT_SOURCE"
    MD5=$(md5sum <"$NGINX_DEFAULT_SOURCE" | cut -d' ' -f1)
    dpkg-query() {
        case $1 in
            -S) printf 'nginx-common: %s\n' "$2" ;;
            -W) printf ' /etc/nginx/nginx.conf 0123\n %s %s\n' "$NGINX_DEFAULT_SOURCE" "$MD5" ;;
        esac
    }
    local out
    # as the package left it: turned off, as before
    ln -s "$NGINX_DEFAULT_SOURCE" "$NGINX_DEFAULT_SITE"
    nginx_default_site_off 2>/dev/null
    [[ ! -e $NGINX_DEFAULT_SITE && ! -L $NGINX_DEFAULT_SITE ]] || return 1
    # changed by the administrator: stays on, said once
    printf '# my site\n' >>"$NGINX_DEFAULT_SOURCE"
    ln -s "$NGINX_DEFAULT_SOURCE" "$NGINX_DEFAULT_SITE"
    out=$(nginx_default_site_off 2>&1)
    [[ -L $NGINX_DEFAULT_SITE && $out == *"« default » of nginx was changed"* ]] || return 1
    out=$(nginx_default_site_off 2>&1)
    [[ -z $out && -L $NGINX_DEFAULT_SITE ]] || return 1
    # a site of his own named default (a file, not the link): stays on
    rm "$NGINX_DEFAULT_SITE"
    printf 'server { }\n' >"$NGINX_DEFAULT_SITE"
    nginx_default_site_off 2>/dev/null
    [[ -f $NGINX_DEFAULT_SITE ]] && declare -f seedbox_apply_nginx | grep -q nginx_default_site_off
)

# --- page « access denied » ------------------------------------------------

# Without the password, nginx showed its grey page « 401 Authorization
# Required ». Now a page in the colors of seedtunnel, without its name (nothing
# tells what is behind), only if the page is there (without it, nginx would
# answer 404 and never ask for the password)
denied_page_discreet() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seed.example.net
    TRANSMISSION_RPC_PORT=9091
    dpkg-query() { echo "4.1.0~beta2+dfsg-3+deb13u1"; }
    nginx_generate_site >"$WORK/site"
    grep -qF "error_page 401 /seedtunnel/denied.html;" "$WORK/site" \
        && grep -A5 "location = /seedtunnel/denied.html {" "$WORK/site" | grep -qF "auth_basic off;" \
        && grep -A5 "location = /seedtunnel/denied.html {" "$WORK/site" | grep -qF "internal;" \
        && grep -qF "alias $ROOT/web/unauthorized.html;" "$WORK/site" || {
        cat "$WORK/site"
        return 1
    }
    # page missing: nginx as before
    if (APP_DIR=$WORK/elsewhere nginx_generate_site | grep -q "error_page"); then return 1; fi
    # the page stands alone (no script, nothing fetched elsewhere) and names nothing
    local page=$ROOT/web/unauthorized.html
    if grep -qiE 'https?:|src=|href=|<script|transmission|seedtunnel|seedbox|password|mot de passe' "$page"; then return 1; fi
    grep -q "Accès refusé" "$page" && grep -q "Access denied" "$page" && ! grep -qE '^web( |/)' "$ROOT/.gitattributes"
)

# Transmission stopped (disk almost full) or starting again: a page in the
# colors of seedtunnel instead of the grey « 502 Bad Gateway » of nginx. For
# the whole site (an error_page in /transmission/ would make the page of the
# refused password forgotten there), only if the page is there; the page
# stands alone and says what to do
stopped_page_instead_of_502() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seed.example.net
    TRANSMISSION_RPC_PORT=9091
    dpkg-query() { echo "1:4.0.6-1"; }
    nginx_generate_site >"$WORK/site-stopped"
    grep -qx "    error_page 502 504 /seedtunnel/transmission-stopped.html;" "$WORK/site-stopped" \
        && grep -A5 "location = /seedtunnel/transmission-stopped.html {" "$WORK/site-stopped" | grep -qF "auth_basic off;" \
        && grep -A5 "location = /seedtunnel/transmission-stopped.html {" "$WORK/site-stopped" | grep -qF "internal;" \
        && grep -qF "alias $ROOT/web/transmission-stopped.html;" "$WORK/site-stopped" || {
        cat "$WORK/site-stopped"
        return 1
    }
    # no error_page of its own in /transmission/: the page of the refused
    # password stays there
    [[ -z $(sed -n '/location \/transmission\/ {/,/^    }/p' "$WORK/site-stopped" | grep error_page) ]] || return 1
    # page missing: nginx as before
    if (APP_DIR=$WORK/elsewhere nginx_generate_site | grep -q "error_page 502"); then return 1; fi
    local page=$ROOT/web/transmission-stopped.html
    if grep -qiE 'https?:|src=|href=|<script' "$page"; then return 1; fi
    grep -q "Transmission ne répond pas" "$page" && grep -q "Transmission is not responding" "$page" \
        && grep -q "sudo seedtunnel doctor" "$page" && ! grep -qE '^web( |/)' "$ROOT/.gitattributes"
)

# --- pages of the one-time links ----------------------------------------------

# The page of a link, in the colors of seedtunnel: the button, single use, the
# numbered steps (only if there are some), the note; nothing fetched elsewhere
share_page_in_colors() (
    load
    local page
    page=$(share_generate_page phone.conf 'VPN configuration "phone"' "<li>One</li>
<li>Two</li>" "Delete it once imported.")
    [[ $page == *'<html lang="en">'* && $page == *'<title>VPN configuration "phone"</title>'* &&
        $page == *'<a class="button" href="phone.conf" download>Download phone.conf</a>'* &&
        $page == *'File: <code>phone.conf</code>'* &&
        $page == *"One time only · valid for $((SHARE_LIFETIME / 60)) minutes"* &&
        $page == *'<h2>Next</h2>'* && $page == *'<li>Two</li>'* &&
        $page == *'Delete it once imported. Opening this page does not use the link up'* &&
        $page == *'<b>Seed</b><span>Tunnel</span> · download link'* ]] || {
        printf '%s\n' "$page"
        return 1
    }
    if grep -qiE 'https?:|src=|url\(|@import|<script|<link' <<<"$page"; then return 1; fi
    # no step: no title « Next » and no empty list
    page=$(share_generate_page backup.gpg Backup "" "Encrypted.")
    [[ $page != *'<h2>'* && $page != *'<ol>'* ]] || return 1
    # in French
    i18n_load fr
    page=$(share_generate_page phone.conf 'Configuration VPN « phone »' "<li>Ouvrez « Outils » : choisissez « OK ».</li>" "Note ?")
    # French punctuation glued to its word with no-break spaces: never alone
    # at the start or the end of a line
    local nbsp=$'\xc2\xa0'
    [[ $page == *'<html lang="fr">'* && $page == *'Télécharger phone.conf'* && $page == *"Fichier$nbsp: <code>"* &&
        $page == *'Usage unique · valable 10 minutes'* && $page == *'<h2>Ensuite</h2>'* &&
        $page == *"<title>Configuration VPN «${nbsp}phone$nbsp»</title>"* &&
        $page == *"<li>Ouvrez «${nbsp}Outils$nbsp»$nbsp: choisissez «${nbsp}OK$nbsp».</li>"* &&
        $page == *"Note$nbsp? Ouvrir cette page ne compte pas$nbsp: seul"* ]] || {
        printf '%s\n' "$page"
        return 1
    }
)

# A link used, expired or unknown: a page that says so instead of the grey 404
# of nginx, with the headers and the access log of the links (the token stays
# hidden), only if the page is there; the page names nothing
share_gone_page() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seed.example.net
    TRANSMISSION_RPC_PORT=9091
    dpkg-query() { echo "4.1.0~beta2+dfsg-3+deb13u1"; }
    nginx_generate_site >"$WORK/site"
    local share gone
    share=$(sed -n '/location ^~ \/share\/ {/,/^    }/p' "$WORK/site")
    gone=$(sed -n '/location = \/seedtunnel\/link-gone.html {/,/^    }/p' "$WORK/site")
    grep -qF "error_page 404 /seedtunnel/link-gone.html;" <<<"$share" \
        && grep -qF "internal;" <<<"$gone" && grep -qF "auth_basic off;" <<<"$gone" \
        && grep -qF "alias $ROOT/web/link-gone.html;" <<<"$gone" \
        && grep -qF "access_log /var/log/nginx/access.log seedtunnel_share;" <<<"$gone" \
        && grep -qF "Content-Security-Policy \"default-src 'none'" <<<"$gone" \
        && grep -qF 'X-Robots-Tag "noindex, nofollow"' <<<"$gone" \
        && grep -qF 'Strict-Transport-Security' <<<"$gone" || {
        cat "$WORK/site"
        return 1
    }
    # page missing: the 404 of nginx, as before
    if (APP_DIR=$WORK/elsewhere nginx_generate_site | grep -q "link-gone"); then return 1; fi
    # the page stands alone and names nothing; its lifetime is the real one
    local page=$ROOT/web/link-gone.html
    if grep -qiE 'https?:|src=|href=|url\(|<script|transmission|seedtunnel|seedbox' "$page"; then return 1; fi
    grep -q "Lien déjà utilisé ou expiré" "$page" && grep -q "Link already used or expired" "$page" \
        && (($(grep -c "pendant $((SHARE_LIFETIME / 60))&nbsp;minutes\|for $((SHARE_LIFETIME / 60))&nbsp;minutes" "$page") == 2))
)

# The folder of the links (/share/) was the grey 403 of nginx: now a 404 with
# the page « nothing here », on the site of the seedbox (no password) as on the
# site of the links, the page given once; only if the page is there
share_folder_nothing_here() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seed.example.net
    TRANSMISSION_RPC_PORT=9091
    dpkg-query() { echo "4.1.0~beta2+dfsg-3+deb13u1"; }
    local site folder nothing
    nginx_generate_site >"$WORK/site-folder"
    site=$(<"$WORK/site-folder")
    folder=$(sed -n '/location = \/share\/ {/,/^    }/p' <<<"$site")
    nothing=$(sed -n '/location = \/seedtunnel\/nothing-here.html {/,/^    }/p' <<<"$site")
    [[ $folder == $'    location = /share/ {\n        auth_basic off;\n        error_page 404 /seedtunnel/nothing-here.html;\n        return 404;\n    }' ]] \
        && grep -qF "internal;" <<<"$nothing" && grep -qF "auth_basic off;" <<<"$nothing" \
        && grep -qF "alias $ROOT/web/nothing-here.html;" <<<"$nothing" \
        && grep -qF "Content-Security-Policy \"default-src 'none'" <<<"$nothing" \
        && grep -qF 'X-Robots-Tag "noindex, nofollow"' <<<"$nothing" \
        && grep -qF 'Strict-Transport-Security' <<<"$nothing" || {
        printf '%s\n' "$site"
        return 1
    }
    # the site of the links: the same folder, the page given once
    VPN_PUBLIC_ADDRESS=203.0.113.7
    LINKS_CERTIFICATE=selfsigned
    site=$(links_run links_generate_site)
    [[ $(sed -n '/location = \/share\/ {/,/^    }/p' <<<"$site") == "$folder" ]] \
        && (($(grep -c "location = /seedtunnel/nothing-here.html {" <<<"$site") == 1)) || {
        printf '%s\n' "$site"
        return 1
    }
    # page missing: the 403 of nginx, as before
    if (APP_DIR=$WORK/elsewhere nginx_generate_site | grep -qF "location = /share/"); then return 1; fi
    if (APP_DIR=$WORK/elsewhere links_run links_generate_site | grep -qF "location = /share/"); then return 1; fi
)

# Any other address of the site of the seedbox (/share, a typo…): once the
# password is given, a 404 with the page « nothing here » instead of the grey
# one of nginx, and nothing of its default folder. The password first:
# try_files, never a « return » (it would answer before the password is
# asked). Without the page, the 404 of nginx.
seedbox_other_addresses_nothing_here() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seed.example.net
    TRANSMISSION_RPC_PORT=9091
    dpkg-query() { echo "4.1.0~beta2+dfsg-3+deb13u1"; }
    local site https last=$'    location / {\n        try_files /.seedtunnel-no-such-file =404;\n    }\n}'
    site=$(nginx_generate_site)
    https=$(sed -n '/listen 443 ssl;/,$p' <<<"$site")
    grep -qx "    error_page 404 /seedtunnel/nothing-here.html;" <<<"$https" \
        && grep -qx "    error_page 401 /seedtunnel/denied.html;" <<<"$https" \
        && [[ $https == *"$last" ]] || {
        printf '%s\n' "$site"
        return 1
    }
    # the page itself needs no password (asked before it)
    grep -A2 "location = /seedtunnel/nothing-here.html {" <<<"$https" | grep -qF "auth_basic off;" || return 1
    # page missing: the 404 of nginx, still nothing of its default folder
    site=$(APP_DIR=$WORK/elsewhere nginx_generate_site)
    [[ $site != *nothing-here* && $site == *"$last" ]]
)

# The request for the password names nothing: « Seedbox » went to anyone,
# robots included (header WWW-Authenticate), before any password
password_request_names_nothing() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seed.example.net
    TRANSMISSION_RPC_PORT=9091
    dpkg-query() { echo "4.1.0~beta2+dfsg-3+deb13u1"; }
    nginx_generate_site >"$WORK/site-realm"
    grep "auth_basic " "$WORK/site-realm"
    [[ $(grep -c 'auth_basic "' "$WORK/site-realm") == 1 ]] && grep -qF 'auth_basic "Restricted";' "$WORK/site-realm"
)

# Web interface on Debian 12 (Transmission 3, another page): its own style
# sheet, in the colors of seedtunnel, not the page as it comes.
web_interface_style_transmission3() (
    load
    SEEDBOX_CERTIFICATE=letsencrypt
    SEEDBOX_DOMAIN=seed.example.net
    TRANSMISSION_RPC_PORT=9091
    VERSION="3.00-2.1+deb12u1"
    dpkg-query() { echo "$VERSION"; }
    nginx_generate_site >"$WORK/site3"
    grep -qF "sub_filter '</head>' '<link href=\"/seedtunnel/transmission3-theme.css\" rel=\"stylesheet\" /></head>';" "$WORK/site3" \
        && grep -qF "alias $ROOT/web/transmission3-theme.css;" "$WORK/site3" \
        && grep -qF "<title>SeedTunnel · Transmission</title>" "$WORK/site3" \
        && ! grep -q "transmission-theme.css" "$WORK/site3" || {
        cat "$WORK/site3"
        return 1
    }
    # Transmission 2 or a version unreadable: the page as it comes
    VERSION="2.94-2"
    if nginx_generate_site | grep -q "sub_filter"; then return 1; fi
    VERSION=""
    if nginx_generate_site | grep -q "sub_filter"; then return 1; fi
    # style sheet missing: the page as it comes, never a link to nothing
    VERSION="3.00-2.1+deb12u1"
    if (APP_DIR=$WORK/elsewhere nginx_generate_site | grep -q "sub_filter"); then return 1; fi
    # only colors: the sheet changes no size, no layout, hides nothing
    if grep -E '(^|[^-])(width|height|display|position|float|margin|padding|font-size)[[:space:]]*:' "$ROOT/web/transmission3-theme.css" | grep .; then return 1; fi
    grep -q "torrent_progress_bar.complete.leeching" "$ROOT/web/transmission3-theme.css"
)

# Home screen in 80 columns: the details under the blocks go on to the next
# line, never cut (« il y a 3 jo… » could hide the age of the last backup)
home_details_never_cut() (
    load
    local out line
    i18n_load fr
    UI_COLUMNS=80
    ui_width
    ui_status_add ok VPN "$(t 'running')" "$(t '%s of %s clients connected' 2 3)"
    ui_status_add ok Seedbox "$(t 'running')"
    ui_status_add ok "$(t 'Firewall')" "$(t 'on')"
    ui_status_add info "$(t 'Disk')" "$(t '%s%%' 62)" "$(t '%s free' "$(human_size_spaced 73014444032)")"
    ui_status_add ok "$(t 'Backup')" "$(t 'recent')" "$(t 'last backup %s' "$(days_ago 13)")" "$(days_ago 13)"
    out=$(ui_status_show | sed 's/\x1b\[[0-9;]*m//g')
    echo "$out"
    [[ $out != *…* && $out == *"clients connectés : 2 sur 3 · 68 Go libres"* && $out == *"· dernière sauvegarde il y a 13 jours"* ]] || return 1
    while IFS= read -r line; do
        ui_len "$line"
        ((UI_LEN <= UI_WIDTH)) || return 1
    done <<<"$out"
)

# The preview shows the labels of the real menus, in French too
preview_labels_are_those_of_the_menus() (
    load
    local out key label function unseen=0
    out=$(TERM=xterm "$ROOT/tools/preview.sh" --all --fr --no-color --columns 100 2>&1) || return 1
    i18n_load fr
    for function in main_menu vpn_menu seedbox_menu backup_menu; do
        while IFS='|' read -r key label; do
            # the preview shows a server with everything installed
            [[ $label == Install* ]] && continue
            # one column or two
            if ! grep -qE -- "^ .*\[${key^^}\] $(sed 's/[][\.*^$(){}?+|/]/\\&/g' <<<"$(t "$label")")( {2}|$)" <<<"$out"; then
                echo "not in the preview: [${key^^}] $(t "$label")"
                unseen=1
            fi
        done < <(declare -f "$function" | sed -nE "s/.*ui_menu_add ([0-9a-z]+) \"\\\$\(t '([^']+)'\)\".*/\1|\2/p")
    done
    for function in vpn_menu seedbox_menu_fields; do
        while IFS= read -r label; do
            if ! grep -qE -- "^  $(t "$label") +[^ ]" <<<"$out"; then
                echo "field not in the preview: $(t "$label")"
                unseen=1
            fi
        done < <(declare -f "$function" | sed -nE "s/.*ui_field_add \"\\\$\(t '([^']+)'\)\".*/\1/p")
    done
    ((unseen == 0)) && grep -q "Services *Transmission ● · nginx ● · fail2ban ●$" <<<"$out"
)

# The archive of a version comes with its attestation (signed proof of where
# and how it was built); the action is pinned to one commit
release_attested() (
    local file="$ROOT/.github/workflows/release.yml"
    grep -qE '^ +uses: actions/attest@[0-9a-f]{40} # v[0-9]' "$file" \
        && grep -qE '^ +id-token: write$' "$file" && grep -qE '^ +attestations: write$' "$file" \
        && grep -qE '^ +subject-path: seedtunnel-.*\.tar\.gz$' "$file"
)

# The archive of a version: folders in 755, files in 644 (git makes them 775
# and 664 by default). An update makes them so whatever its archive says.
release_archive_not_group_writable() (
    load
    grep -qE '^ +git -c tar\.umask=0022 archive ' "$ROOT/.github/workflows/release.yml" || return 1
    local src="$WORK/archive-modes/src" out="$WORK/archive-modes/out"
    rm -rf "$WORK/archive-modes"
    mkdir -p "$src/seedtunnel-9.9.9/lib" "$out"
    echo 'echo ok' >"$src/seedtunnel-9.9.9/seedtunnel.sh"
    echo ': ' >"$src/seedtunnel-9.9.9/lib/common.sh"
    chmod 775 "$src/seedtunnel-9.9.9" "$src/seedtunnel-9.9.9/lib" "$src/seedtunnel-9.9.9/seedtunnel.sh"
    chmod 664 "$src/seedtunnel-9.9.9/lib/common.sh"
    tar -czf "$WORK/archive-modes/a.tar.gz" -C "$src" seedtunnel-9.9.9
    update_extract "$WORK/archive-modes/a.tar.gz" "$out" || return 1
    find "$out/seedtunnel-9.9.9" -printf '%m %p\n'
    [[ -z $(find "$out/seedtunnel-9.9.9" -perm /022) ]] \
        && [[ $(stat -c %a "$out/seedtunnel-9.9.9/seedtunnel.sh") == 755 && $(stat -c %a "$out/seedtunnel-9.9.9/lib/common.sh") == 644 ]]
)

# --- Ubuntu 24.04 / 26.04, Debian 11 ---------------------------------------

# os_release ID VERSION_ID PRETTY_NAME → a file /etc/os-release for the tests
os_release() {
    APP_OS_RELEASE="$WORK/os-release"
    APP_OS_ID=""
    printf 'PRETTY_NAME="%s"\nNAME="%s"\nVERSION_ID="%s"\nID=%s\n' "$3" "${3%% *}" "$2" "$1" >"$APP_OS_RELEASE"
}

systems_supported() (
    load
    local system out
    for system in "debian 12 Debian GNU/Linux 12 (bookworm)" "debian 13 Debian GNU/Linux 13 (trixie)" \
        "ubuntu 24.04 Ubuntu 24.04.3 LTS" "ubuntu 26.04 Ubuntu 26.04 LTS"; do
        read -r id version pretty <<<"$system"
        os_release "$id" "$version" "$pretty"
        (os_check) || return 1
    done
    # neither an older nor a short-lived Ubuntu, nor another system
    for system in "ubuntu 22.04 Ubuntu 22.04.5 LTS" "ubuntu 25.10 Ubuntu 25.10" "fedora 41 Fedora Linux 41" "debian 10 Debian GNU/Linux 10 (buster)"; do
        read -r id version pretty <<<"$system"
        os_release "$id" "$version" "$pretty"
        if out=$( (os_check) 2>&1); then return 1; fi
        echo "$out"
        [[ $out == *"Debian 12/13, Ubuntu 24.04/26.04"*"$pretty"* ]] || return 1
    done
)

debian11_refused_with_the_way_up() (
    load
    local out
    os_release debian 11 "Debian GNU/Linux 11 (bullseye)"
    if out=$( (os_check) 2>&1); then return 1; fi
    echo "$out"
    [[ $out == *"no longer supports it"*"Debian 12, then to Debian 13"*"debian.org"* ]] || return 1
    i18n_load fr
    out=$( (os_check) 2>&1) || true
    [[ $out == *"ne le prend plus en charge"*"Debian 12, puis à Debian 13"* ]]
)

header_names_ubuntu() (
    load
    os_release ubuntu 26.04 "Ubuntu 26.04.1 LTS"
    UI_SYSTEM=""
    ui_server_names
    echo "$UI_SYSTEM"
    [[ $UI_SYSTEM == "Ubuntu 26.04" ]] || return 1
    os_release debian 13 "Debian GNU/Linux 13 (trixie)"
    UI_SYSTEM=""
    ui_server_names
    [[ $UI_SYSTEM == "Debian 13" ]]
)

# On the right of the header: the full name of the server, its IPv4 address,
# its system. On a narrow screen: the system next to the version, the name
# and the address under the subtitle; nothing wider than the screen.
header_name_address_system() (
    load
    colors_init off
    UI_SERVER=vps-1234.example.net
    UI_ADDRESS=203.0.113.10
    UI_ADDRESS_READ=1
    UI_SYSTEM="Debian 12"
    local header
    UI_COLUMNS=80
    ui_width
    header=$(ui_header)
    [[ $(sed -n 1p <<<"$header") == *" vps-1234.example.net" ]] \
        && [[ $(sed -n 2p <<<"$header") == *"  203.0.113.10" ]] \
        && [[ $(sed -n 3p <<<"$header") == *"  Debian 12" ]] || {
        printf '%s\n' "$header"
        return 1
    }
    UI_COLUMNS=40
    ui_width
    header=$(ui_header)
    [[ $(sed -n 1p <<<"$header") == "SeedTunnel  v$APP_VERSION"*"  Debian 12" ]] \
        && [[ $(sed -n 3p <<<"$header") == "vps-1234.example.net  "*"203.0.113.10" ]] || {
        printf '%s\n' "$header"
        return 1
    }
    # no address: the name alone
    UI_ADDRESS=""
    header=$(ui_header)
    [[ $(sed -n 3p <<<"$header") == "vps-1234.example.net" && $(wc -l <<<"$header") == 3 ]] || return 1
    # the name: the full one when the system knows it, else the short one
    mkdir -p "$WORK/bin-host"
    printf '#!/bin/sh\necho vps-1234.example.net\n' >"$WORK/bin-host/hostname"
    chmod +x "$WORK/bin-host/hostname"
    UI_SERVER=""
    PATH="$WORK/bin-host:$PATH" ui_server_names
    [[ $UI_SERVER == vps-1234.example.net ]] || return 1
    printf '#!/bin/sh\necho "hostname: Name or service not known" >&2\nexit 1\n' >"$WORK/bin-host/hostname"
    UI_SERVER=""
    HOSTNAME=vps-1234 PATH="$WORK/bin-host:$PATH" ui_server_names
    [[ $UI_SERVER == vps-1234 ]] || return 1
    # the address: the one the server goes out with, read on the server (the
    # route), once; nothing when there is none
    ip() { echo "1.1.1.1 via 198.51.100.1 dev eth0 src 198.51.100.7 uid 0"; }
    UI_ADDRESS_READ=0
    ui_server_names
    [[ $UI_ADDRESS == 198.51.100.7 ]] || return 1
    ip() { echo "called" >>"$WORK/ip-calls"; }
    ui_server_names
    [[ ! -e $WORK/ip-calls && $UI_ADDRESS == 198.51.100.7 ]] || return 1
    ip() { return 2; }
    UI_ADDRESS_READ=0
    ui_server_names
    [[ -z $UI_ADDRESS ]]
)

packages_without_candidate_stop() (
    packages_load
    local out
    apt-get() { echo "apt-get $*" >>"$WORK/apt-calls"; }
    # fail2ban is in « universe », turned off; qrencode is not known at all
    apt-cache() {
        case $2 in
            fail2ban) printf 'fail2ban:\n  Installed: (none)\n  Candidate: (none)\n' ;;
            qrencode) ;;
            *) apt_cache_policy "$2" ;;
        esac
    }
    APP_OS_ID=ubuntu
    if out=$( (apt_install nginx fail2ban qrencode) 2>&1); then return 1; fi
    echo "$out"
    [[ $out == *"fail2ban qrencode"*"add-apt-repository universe"* ]] || return 1
    # nothing installed, nothing written in the list of packages
    ! grep -q " install " "$WORK/apt-calls" 2>/dev/null && [[ ! -s $APP_STATE_DIR/packages ]] || return 1
    # on Debian: the repositories, without « universe »
    APP_OS_ID=debian
    out=$( (apt_install fail2ban) 2>&1) || true
    [[ $out == *"fail2ban"*"sources.list"* && $out != *universe* ]] || return 1
    # every package known: installed
    apt-cache() { apt_cache_policy "$2"; }
    apt_install fail2ban &>/dev/null && grep -q " install -y --no-install-recommends fail2ban" "$WORK/apt-calls"
)

apt_never_lets_needrestart_restart() (
    packages_load
    apt-get() { echo "NEEDRESTART_SUSPEND=${NEEDRESTART_SUSPEND-} NEEDRESTART_MODE=${NEEDRESTART_MODE-} DEBIAN_FRONTEND=${DEBIAN_FRONTEND-} $*" >>"$WORK/apt-calls"; }
    apt_install fail2ban &>/dev/null || return 1
    cat "$WORK/apt-calls"
    grep -q "^NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive .* install " "$WORK/apt-calls" || return 1
    # removals too
    rm -f "$WORK/apt-calls"
    printf '%s\n' certbot >>"$WORK/installed"
    printf '%s\n' certbot >"$APP_STATE_DIR/packages"
    apt-get() {
        echo "NEEDRESTART_SUSPEND=${NEEDRESTART_SUSPEND-} NEEDRESTART_MODE=${NEEDRESTART_MODE-} $*" >>"$WORK/apt-calls"
        if [[ $1 == -s && $* == *" purge "* ]]; then echo "Purg certbot [1.0]"; fi
    }
    apt_purge certbot &>/dev/null || return 1
    cat "$WORK/apt-calls"
    grep -q "^NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l .* purge -y certbot" "$WORK/apt-calls"
)

ssh_socket_ports_kept_open() (
    load
    local ports
    unset SSH_CONNECTION
    # sshd says 2222 (changed by hand), ssh.socket still listens on 22
    sshd() { printf 'port 2222\nlistenaddress [::]:2222\n'; }
    systemctl() {
        case "$*" in
            "is-active --quiet ssh.socket") return 0 ;;
            "show -p Listen --value ssh.socket") printf '[::]:22 (Stream)\n0.0.0.0:22 (Stream)\n' ;;
            *) return 1 ;;
        esac
    }
    ss() { :; }
    ports=$(firewall_ssh_ports)
    echo "$ports"
    [[ $ports == "2222, 22" ]] || return 1
    ports=$(firewall_sshd_ports | paste -sd' ')
    echo "$ports"
    [[ $ports == "2222 22" ]] || return 1
    # without ssh.socket: as before
    systemctl() { return 1; }
    [[ $(firewall_ssh_ports) == 2222 ]]
)

doctor_ssh_waiting_on_socket() (
    load
    local out
    systemctl() {
        case "$*" in
            "is-active --quiet ssh.socket") return 0 ;;
            *) return 1 ;;
        esac
    }
    DOCTOR_ERRORS=0
    out=$(doctor_ssh 2>&1)
    echo "$out"
    ((DOCTOR_ERRORS == 0)) && [[ $out == *"waiting for connections (ssh.socket)"* ]] || return 1
    # neither the service nor the socket: an error, as before
    systemctl() { return 1; }
    DOCTOR_ERRORS=0
    doctor_ssh &>/dev/null
    ((DOCTOR_ERRORS == 1)) && declare -f doctor_seedbox | grep -q doctor_ssh
)

sshd_checked_before_any_connection() (
    load
    local out
    # SSH started on demand, nobody connected yet: no /run/sshd
    rm -rf "$SSHD_RUNTIME_DIR"
    sshd() {
        if [[ ! -d $SSHD_RUNTIME_DIR ]]; then
            echo "Missing privilege separation directory: $SSHD_RUNTIME_DIR" >&2
            return 255
        fi
        if [[ $1 == -T ]]; then printf 'port 2222\n'; fi
    }
    systemctl() { return 1; }
    unset SSH_CONNECTION
    out=$(firewall_ssh_ports)
    echo "$out"
    [[ $out == 2222 && -d $SSHD_RUNTIME_DIR ]] || return 1
    # and before « sshd -t », which checks the configuration of the seedbox
    declare -f seedbox_apply_sftp | grep -B1 'sshd -t' | grep -q sshd_runtime_dir
)

# ufw_on → a command ufw that says it is active
ufw_on() {
    ufw() { [[ $1 == status ]] && printf 'Status: active\n\nTo                         Action      From\n'; }
}

ufw_stops_the_installations() (
    load
    local out step
    ufw_on
    # nothing may be installed or changed
    apt_install() { echo "apt_install $*" >>"$WORK/ufw-calls"; }
    apt-get() { echo "apt-get $*" >>"$WORK/ufw-calls"; }
    nft() { echo "nft $*" >>"$WORK/ufw-calls"; }
    base_setup() { echo base_setup >>"$WORK/ufw-calls"; }
    vpn_check_kernel() { :; }
    seedbox_check_web_ports() { :; }
    public_ipv4() { echo 203.0.113.10; }
    INTERACTIVE=0
    SEEDBOX_USER=lancelot
    for step in vpn_install_interactive vpn_install_from_config seedbox_install_interactive seedbox_install_from_config firewall_enable; do
        rm -f "$WORK/ufw-calls"
        if out=$( ($step) 2>&1 </dev/null); then
            echo "$step went on"
            return 1
        fi
        if [[ $out != *"sudo ufw disable"* || -s $WORK/ufw-calls ]]; then
            echo "$step: $out"
            cat "$WORK/ufw-calls" 2>/dev/null
            return 1
        fi
    done
    # « Status: inactive »: no refusal (only the start is looked at, in English)
    ufw() { printf 'Status: inactive\n'; }
    ! ufw_active && (ufw_refuse)
)

doctor_says_ufw() (
    load
    ufw_on
    vpn_installed() { return 0; }
    firewall_enabled() { return 1; }
    systemctl() { return 1; }
    DOCTOR_ERRORS=0
    doctor_firewall >"$WORK/ufw.out" 2>&1
    cat "$WORK/ufw.out"
    ((DOCTOR_ERRORS == 1)) && grep -q "ufw.*sudo ufw disable" "$WORK/ufw.out" || return 1
    # without ufw: nothing said about it
    ufw() { printf 'Status: inactive\n'; }
    DOCTOR_ERRORS=0
    doctor_firewall >"$WORK/ufw.out" 2>&1
    ((DOCTOR_ERRORS == 0)) && ! grep -q ufw "$WORK/ufw.out"
)

restore_from_another_system_said() (
    load
    local out
    mkdir -p "$WORK/other/etc/seedtunnel"
    APP_OS_ID=debian APP_OS_VERSION=12
    # made on Ubuntu 24.04: said, nothing asked (tested on real servers)
    printf 'ubuntu 24.04\n' >"$WORK/other/etc/seedtunnel/system"
    OPT_YES=0
    confirm() {
        echo asked
        return 1
    }
    out=$( (restore_check_system "$WORK/other") 2>&1 </dev/null) || return 1
    echo "$out"
    [[ $out == *"Backup made on Ubuntu 24.04, restored on Debian 12."* && $out != *asked* ]] || return 1
    # the same system, or a backup that does not say its system: nothing said
    printf 'debian 12\n' >"$WORK/other/etc/seedtunnel/system"
    out=$( (restore_check_system "$WORK/other") 2>&1 </dev/null) || return 1
    [[ -z $out ]] || return 1
    rm "$WORK/other/etc/seedtunnel/system"
    out=$( (restore_check_system "$WORK/other") 2>&1 </dev/null) || return 1
    [[ -z $out ]] || return 1
    # the backup notes the system of the server
    BACKUP_SYSTEM_FILE="$WORK/system"
    backup_note_system
    [[ $(<"$WORK/system") == "debian 12" ]] && declare -f backup_write | grep -q backup_note_system \
        && declare -f restore_main | grep -q restore_check_system
)

# -----------------------------------------------------------------------------------

# A path pasted with a space at the end was « not found » (restore): the
# spaces around an answer are not part of it
answers_without_spaces_around() (
    load
    INTERACTIVE=1
    local answer=""
    ask_back answer 'Path of the backup file' "" <<<"  /tmp/a b.enc   " || return 1
    [[ $answer == "/tmp/a b.enc" ]] || return 1
    # spaces only: back
    if ask_back answer 'Path of the backup file' "" <<<"    "; then return 1; fi
    ask answer 'Your choice' "" <<<" R "
    [[ $answer == R ]]
)

# Restore: the backups of the server and those copied into /root or /home,
# numbered, the newest first; a number or a path (between quotes too)
restore_picks_a_backup_by_number() (
    back_load
    local file
    rm -rf "$WORK/pick"
    BACKUP_DIR="$WORK/pick/backups"
    BACKUP_COPIED=("$WORK/pick/home/*/*.tar.gz.enc")
    mkdir -p "$BACKUP_DIR" "$WORK/pick/home/ubuntu" "$WORK/pick/with space"
    touch -d '3 days ago' "$BACKUP_DIR/seedtunnel-old.tar.gz.enc"
    touch -d '1 hour ago' "$WORK/pick/home/ubuntu/seedtunnel-copied.tar.gz.enc"
    touch "$WORK/pick/with space/x.enc"
    # a number not in the list is asked again; 2: the oldest
    answers "9" "2"
    backup_pick_file file >"$WORK/pick.out" 2>&1 || return 1
    cat "$WORK/pick.out"
    # a table: number, date, size, kind (copied, by hand, weekly), folder
    [[ $file == "$BACKUP_DIR/seedtunnel-old.tar.gz.enc" ]] && grep -q "No backup number 9" "$WORK/pick.out" \
        && grep -q "^ *# *DATE *SIZE *KIND *FOLDER$" "$WORK/pick.out" \
        && grep -q "^ *1 .* copied *$WORK/pick/home/ubuntu$" "$WORK/pick.out" \
        && grep -q "^ *2 .* by hand *$BACKUP_DIR$" "$WORK/pick.out" || return 1
    # the same list for « seedtunnel backup list »
    (($(backup_list | grep -c 'tar.gz.enc$') == 2)) || return 1
    # a path between quotes, with a space in it
    answers "'$WORK/pick/with space/x.enc'"
    backup_pick_file file >/dev/null 2>&1 && [[ $file == "$WORK/pick/with space/x.enc" ]] || return 1
    # nothing found: said, the path is asked; empty: back
    BACKUP_DIR="$WORK/pick/none"
    BACKUP_COPIED=()
    answers ""
    backup_pick_file file >"$WORK/pick.out" 2>&1
    (($? == 1)) && grep -q "No backup found in $WORK/pick/none, nor directly in /root or in a folder of /home." "$WORK/pick.out"
)

# My backups: the list numbered (by command too), one downloaded by its
# number, deleted after a question in red (the last one of the server said, a
# copy put there by hand said too); a file outside the list never deleted
backup_list_download_delete() (
    back_load
    local file auto="" hand="" copied=""
    rm -rf "$WORK/mine"
    BACKUP_DIR="$WORK/mine/backups"
    BACKUP_COPIED=("$WORK/mine/home/*/*.tar.gz.enc")
    mkdir -p "$BACKUP_DIR" "$WORK/mine/home/ubuntu"
    hand="$BACKUP_DIR/seedtunnel-server-20261109-182200.tar.gz.enc"
    copied="$WORK/mine/home/ubuntu/seedtunnel-copied.tar.gz.enc"
    auto="$BACKUP_DIR/seedtunnel-server-20261112-173000-auto.tar.gz.enc"
    touch -d '3 days ago' "$hand"
    touch -d '1 day ago' "$copied"
    touch "$auto"
    # by command: numbered, the newest first
    backup_list >"$WORK/mine.out"
    cat "$WORK/mine.out"
    grep -q "^  1  .*$auto$" "$WORK/mine.out" && grep -q "^  2  .*$copied$" "$WORK/mine.out" \
        && grep -q "^  3  .*$hand$" "$WORK/mine.out" || return 1
    backup_by_number file 2
    [[ $file == "$copied" ]] || return 1
    if (backup_by_number file 4) >"$WORK/mine.out" 2>&1; then return 1; fi
    grep -q "No backup number 4" "$WORK/mine.out" || return 1
    # downloaded by its number
    banner() { :; }
    share_require() { :; }
    share_create() { echo "share $1" >>"$WORK/mine-calls"; }
    rm -f "$WORK/mine-calls"
    backup_share 3 >/dev/null 2>&1 || return 1
    [[ $(<"$WORK/mine-calls") == "share $hand" ]] || return 1
    # a file outside the list, a link to a backup: never deleted
    touch "$WORK/mine/other.tar.gz.enc"
    ln -sf "$hand" "$WORK/mine/home/ubuntu/link.tar.gz.enc"
    for file in "$WORK/mine/other.tar.gz.enc" "$WORK/mine/home/ubuntu/link.tar.gz.enc" "$BACKUP_DIR/../mine/other.tar.gz.enc"; do
        if (backup_delete "$file") >"$WORK/mine.out" 2>&1; then return 1; fi
        grep -q "Not a backup of the list (seedtunnel backup list)" "$WORK/mine.out" || return 1
    done
    [[ -f $WORK/mine/other.tar.gz.enc && -L $WORK/mine/home/ubuntu/link.tar.gz.enc && -f $hand ]] || return 1
    rm -f "$WORK/mine/home/ubuntu/link.tar.gz.enc"
    # « no »: kept, nothing more said
    confirm() { return 1; }
    backup_delete "$hand" >"$WORK/mine.out" 2>&1 || return 1
    cat "$WORK/mine.out"
    [[ -f $hand ]] && ((WENT_BACK == 1)) && grep -q "is deleted for good" "$WORK/mine.out" \
        && ! grep -q "only backup made by this server" "$WORK/mine.out" || return 1
    # « yes »: deleted
    confirm() { return 0; }
    backup_delete "$hand" >"$WORK/mine.out" 2>&1 || return 1
    [[ ! -e $hand ]] && grep -q "Backup deleted: ${hand##*/}" "$WORK/mine.out" || return 1
    # the last backup of the server: said in the red frame
    confirm() { return 1; }
    backup_delete "$auto" >"$WORK/mine.out" 2>&1 || return 1
    grep -q "It is the only backup made by this server" "$WORK/mine.out" && [[ -f $auto ]] || return 1
    # the menu: a number not in the list asked again; a copied backup: said
    # in the red frame, « no » keeps it, « yes » deletes it
    answers "9" "2"
    backup_menu_mine_delete >"$WORK/mine.out" 2>&1 || return 1
    cat "$WORK/mine.out"
    grep -q "No backup number 9" "$WORK/mine.out" && grep -q "It was copied by hand into $WORK/mine/home/ubuntu" "$WORK/mine.out" \
        && grep -q "it may be your only copy" "$WORK/mine.out" \
        && ! grep -q "only backup made by this server" "$WORK/mine.out" && [[ -f $copied ]] || return 1
    confirm() { return 0; }
    answers "2"
    backup_menu_mine_delete >"$WORK/mine.out" 2>&1 || return 1
    [[ ! -e $copied ]] && grep -q "Backup deleted: ${copied##*/}" "$WORK/mine.out" || return 1
    # the screen: the table, the room taken, the two actions; empty: back
    answers ""
    backup_menu_mine >"$WORK/mine.out" 2>&1 || return 1
    grep -q "My backups" "$WORK/mine.out" && grep -q "Space used" "$WORK/mine.out" \
        && grep -q "Download a backup (one-time link)" "$WORK/mine.out" && grep -q "Delete a backup" "$WORK/mine.out" \
        && grep -q "^ *1 .* weekly .*$BACKUP_DIR" "$WORK/mine.out"
)

# The last connection of a client: connected (green), less than an hour ago
# (yellow), older (grey), « not since the VPN started » instead of « never »
vpn_last_connection_states() (
    load
    [[ $(vpn_last_connection 12) == "● connected (12 s)" && $(vpn_last_connection 420) == "● 7 min ago" ]] || return 1
    [[ $(vpn_last_connection 7200) == "○ 2 h ago" && $(vpn_last_connection 259200) == "○ 3 days ago" ]] || return 1
    [[ $(vpn_last_connection -1) == "○ not since the VPN started" ]] || return 1
    i18n_load fr
    [[ $(vpn_last_connection -1) == "○ pas depuis le démarrage du VPN" && $(vpn_last_connection 420) == "● il y a 7 min" ]]
)

vpn_table_says_since_when() (
    load
    VPN_CLIENTS_DIR="$WORK/table-clients"
    rm -rf "$VPN_CLIENTS_DIR"
    mkdir -p "$VPN_CLIENTS_DIR"
    printf 'CLIENT_NUMBER=1\nCLIENT_PUBLIC_KEY=key1\nCLIENT_PRESHARED_KEY=psk\nCLIENT_PRIVATE_KEY=private\n' >"$VPN_CLIENTS_DIR/laptop.env"
    # stopped: said
    systemctl() { return 1; }
    vpn_status_table >"$WORK/table.out" 2>&1
    cat "$WORK/table.out"
    grep -q "The VPN is stopped: no client can connect." "$WORK/table.out" && grep -q "^  laptop " "$WORK/table.out" || return 1
    # running since…; a client not seen since
    systemctl() {
        case $1 in
            is-active) return 0 ;;
            show) echo "Wed 2026-11-11 02:08:03 UTC" ;;
        esac
    }
    wg() { printf 'private\tserverkey\t51820\toff\nkey1\tpsk\t(none)\t10.8.0.2/32\t0\t0\t0\t25\n'; }
    vpn_status_table >"$WORK/table.out" 2>&1
    cat "$WORK/table.out"
    grep -q "VPN running since 2026-11-1" "$WORK/table.out" && grep -q "○ not since the VPN started" "$WORK/table.out" || return 1
    # no date known: nothing said (never « since midnight »)
    systemctl() { [[ $1 == is-active ]]; }
    vpn_status_table >"$WORK/table.out" 2>&1
    ! grep -q "running since" "$WORK/table.out" && grep -q "^  laptop " "$WORK/table.out"
)

# DNS: four services and « other », changed on a screen of its own, the one in
# use suggested; going back changes nothing
vpn_dns_load() {
    back_load
    vpn_installed() { return 0; }
    vpn_apply() { echo "apply $VPN_DNS" >>"$WORK/back-calls"; }
    vpn_count_clients() { echo 2; }
    VPN_DNS="9.9.9.9, 149.112.112.112"
    # the suggestion of each question is kept
    : >"$WORK/suggested"
    ask_back() {
        local _back_answer
        echo "${3-}" >>"$WORK/suggested"
        ask _back_answer
        [[ -n $_back_answer ]] || return 1
        printf -v "$1" '%s' "$_back_answer"
    }
}

vpn_dns_can_go_back() (
    vpn_dns_load
    # empty choice; « Other » then empty addresses; a wrong choice, then empty
    answers ""
    went_back vpn_change_dns || return 1
    answers "5" ""
    went_back vpn_change_dns || return 1
    answers "8" ""
    went_back vpn_change_dns || return 1
    # the same DNS again: nothing to apply
    answers "1"
    vpn_change_dns >"$WORK/dns.out" 2>&1 || return 1
    grep -q "Nothing to change: the clients already use Quad9 · 9.9.9.9, 149.112.112.112." "$WORK/dns.out" || return 1
    back_nothing_done && [[ $VPN_DNS == "9.9.9.9, 149.112.112.112" ]]
)

vpn_dns_changed() (
    vpn_dns_load
    answers "3"
    vpn_change_dns >"$WORK/dns.out" 2>&1 || return 1
    cat "$WORK/dns.out"
    grep -qx "apply 86.54.11.1, 86.54.11.201" "$WORK/back-calls" && grep -q "DNS of the clients: DNS4EU · 86.54.11.1, 86.54.11.201." "$WORK/dns.out" \
        && grep -q "keeps the old DNS until it imports its configuration again" "$WORK/dns.out" || return 1
    grep -q "· Changing the DNS of the clients: DNS4EU · 86.54.11.1, 86.54.11.201$" "$APP_LOG" || return 1
    # Quad9 was suggested (1)
    [[ $(head -n 1 "$WORK/suggested") == 1 ]] || return 1
    # now DNS4EU: suggested (3); « other », the addresses in use suggested
    VPN_DNS="86.54.11.1, 86.54.11.201"
    : >"$WORK/suggested"
    answers "5" "1.1.1.2, 9.9.9.11"
    vpn_change_dns >/dev/null 2>&1 || return 1
    [[ $(sed -n 1p "$WORK/suggested") == 3 && $(sed -n 2p "$WORK/suggested") == "86.54.11.1, 86.54.11.201" ]] || return 1
    grep -qx "apply 1.1.1.2, 9.9.9.11" "$WORK/back-calls" || return 1
    # by command: a name, or addresses (in two words); refused otherwise
    VPN_DNS="9.9.9.9, 149.112.112.112"
    : >"$WORK/back-calls"
    (vpn_cli dns adguard) >/dev/null 2>&1 || return 1
    (vpn_cli dns 9.9.9.9, 1.1.1.1) >/dev/null 2>&1 || return 1
    if (vpn_cli dns nothing.valid) >/dev/null 2>&1; then return 1; fi
    [[ $(<"$WORK/back-calls") == $'apply 94.140.14.14, 94.140.15.15\napply 9.9.9.9, 1.1.1.1' ]] || return 1
    [[ $( (vpn_cli dns) 2>&1) == "DNS of the clients: Quad9 · 9.9.9.9, 149.112.112.112." ]] || return 1
    # addresses typed by hand: shown alone; the names of the configuration file
    [[ $(vpn_dns_label "1.1.1.2, 9.9.9.11") == "1.1.1.2, 9.9.9.11" && $(vpn_dns_value DNS4EU) == "86.54.11.1, 86.54.11.201" ]]
)

# Bans: the addresses banned right now with the end of their ban (the soonest
# first), or « no address banned »; unbanned by their number
bans_load() {
    back_load
    NOW=$(date +%s)
    systemctl() { [[ $* == "is-active --quiet fail2ban" ]]; }
    FAIL2BAN_SETTLE_DELAY=0
    # end of a ban in N seconds, as fail2ban writes it
    ban_line() { printf '%s \t%s + %s = %s\n' "$1" "$(date -d "@$((NOW - 60))" '+%F %T')" "$2" "$(date -d "@$((NOW + $3))" '+%F %T')"; }
    fail2ban-client() {
        # an address unbanned is no longer banned
        if [[ $1 == banned ]] && grep -qxF "unban $2" "$WORK/back-calls" 2>/dev/null; then
            echo "[[]]"
            return 0
        fi
        case "$*" in
            "get sshd banip --with-time")
                ban_line 203.0.113.7 3600 3000
                ban_line 192.0.2.9 -1 999999999
                ;;
            "get nginx-http-auth banip --with-time") ban_line 2001:db8::17 3600 600 ;;
            "get recidive banip --with-time") ban_line 198.51.100.23 604800 $((6 * 86400 + 120)) ;;
            "status sshd") printf 'Status for the jail: sshd\n`- Actions\n   |- Currently banned:\t2\n   |- Total banned:\t4\n   `- Banned IP list:\t203.0.113.7 192.0.2.9\n' ;;
            "status recidive") printf '`- Actions\n   |- Total banned:\t1\n' ;;
            "banned 203.0.113.7" | "banned 192.0.2.9") echo "[['sshd']]" ;;
            "banned 2001:db8::17") echo "[['nginx-http-auth']]" ;;
            "banned 198.51.100.23") echo "[['recidive', 'sshd']]" ;;
            banned*) echo "[[]]" ;;
            unban*) echo "unban $2" >>"$WORK/back-calls" ;;
        esac
    }
}

bans_listed_with_their_end() (
    bans_load
    local out
    fail2ban_bans_print >"$WORK/bans.out" 2>&1
    out=$(<"$WORK/bans.out")
    echo "$out"
    # the soonest freed first, a ban without end last
    [[ ${FAIL2BAN_LISTED[*]} == "2001:db8::17 203.0.113.7 198.51.100.23 192.0.2.9" ]] || return 1
    grep -qE '^  1\) +2001:db8::17 +nginx-http-auth +([0-9-]{10} )?[0-9]{2}:[0-9]{2} \(in 10 min\)$' <<<"$out" \
        && grep -qE '^  2\) +203\.0\.113\.7 +sshd +([0-9-]{10} )?[0-9]{2}:[0-9]{2} \(in 50 min\)$' <<<"$out" \
        && grep -qE '^  3\) +198\.51\.100\.23 +recidive +[0-9-]{10} [0-9:]{5} \(in 6 days\)$' <<<"$out" \
        && grep -qE '^  4\) +192\.0\.2\.9 +sshd +never \(banned for good\)$' <<<"$out" || return 1
    grep -q "Bans since fail2ban started: 5." <<<"$out" && grep -q "Banned? The VPN still connects" <<<"$out" || return 1
    # unbanned by its number
    answers "2"
    fail2ban_bans_menu >/dev/null 2>&1 || return 1
    grep -qx "unban 203.0.113.7" "$WORK/back-calls"
)

# seedbox unban: an address that is not one refused, one not banned said
# (nothing done, not an error)
unban_checks_the_address() (
    bans_load
    : >"$WORK/back-calls"
    local address
    for address in 999.1.2.3 1.2.3 "" "x;y" 2001:db8:::1; do
        if (fail2ban_unban "$address") >"$WORK/unban.out" 2>&1; then
            echo "accepted: $address"
            return 1
        fi
        grep -q "Invalid IP address" "$WORK/unban.out" || return 1
    done
    fail2ban_unban 1.2.3.4 >"$WORK/unban.out" 2>&1 || return 1
    cat "$WORK/unban.out"
    grep -q "1.2.3.4 is not banned right now: nothing to do." "$WORK/unban.out" && [[ ! -s $WORK/back-calls ]] || return 1
    fail2ban_unban 2001:db8::17 >"$WORK/unban.out" 2>&1 || return 1
    grep -qx "unban 2001:db8::17" "$WORK/back-calls" || return 1
    grep -q "Checking that 2001:db8::17 stays unbanned… ok" "$WORK/unban.out" || return 1
    # unban does not reset what fail2ban counted: said
    grep -q "a few more mistakes within these 10 minutes ban 2001:db8::17 again" "$WORK/unban.out" || return 1
    # without an address: how to use it, nothing done
    : >"$WORK/back-calls"
    seedbox_require_installed() { :; }
    if (seedbox_cli unban) >"$WORK/unban.out" 2>&1; then return 1; fi
    grep -q "Usage: seedtunnel seedbox unban IP" "$WORK/unban.out" && [[ ! -s $WORK/back-calls ]]
)

# seedbox unban right after a ban: recidive bans the address again a moment
# later (it reads the ban in the log of fail2ban): seen, unbanned again
unban_again_after_recidive() (
    bans_load
    FAIL2BAN_SETTLE_DELAY=0
    : >"$WORK/back-calls"
    fail2ban-client() {
        case "$*" in
            "banned 203.0.113.7")
                case $(wc -l <"$WORK/back-calls") in
                    0) echo "[['sshd']]" ;;
                    1) echo "[['recidive']]" ;;
                    *) echo "[[]]" ;;
                esac
                ;;
            unban*) echo "unban $2" >>"$WORK/back-calls" ;;
        esac
    }
    fail2ban_unban 203.0.113.7 >"$WORK/unban.out" 2>&1 || return 1
    cat "$WORK/unban.out"
    [[ $(grep -cx "unban 203.0.113.7" "$WORK/back-calls") == 2 ]] || return 1
    grep -q "banned again (\[\['recidive'\]\]), unbanned again" "$APP_LOG" || return 1
    # banned again each time: said as a failure, not as done
    fail2ban-client() {
        case "$*" in
            banned*) echo "[['recidive']]" ;;
            unban*) echo "unban $2" >>"$WORK/back-calls" ;;
        esac
    }
    if (fail2ban_unban 203.0.113.7) >"$WORK/unban.out" 2>&1; then return 1; fi
    grep -q "Checking that 203.0.113.7 stays unbanned… failed" "$WORK/unban.out"
)

bans_none_or_fail2ban_stopped() (
    bans_load
    fail2ban-client() { :; }
    # no question asked: there is nobody to unban
    fail2ban_bans_menu >"$WORK/bans.out" 2>&1 || return 1
    grep -q "No address banned right now." "$WORK/bans.out" || return 1
    systemctl() { return 1; }
    fail2ban_bans_print >"$WORK/bans.out" 2>&1
    grep -q "fail2ban is not running" "$WORK/bans.out" && ! grep -q "No address banned" "$WORK/bans.out"
)

# Removing the seedbox: the deletion of the certificate, of the user and of the
# download links under their own titles in the log
seedbox_removal_log_titles() (
    load
    declare -f seedbox_letsencrypt_delete | grep -q "log_run \"Deleting the Let's Encrypt certificate\" certbot delete" \
        && declare -f seedbox_uninstall | grep -q "seedbox_letsencrypt_delete" \
        && declare -f seedbox_uninstall | grep -q "log_run 'Stopping the download links in progress' systemctl stop" \
        && ! declare -f seedbox_uninstall | grep -q 'APP_LOG' || return 1
    # python3-systemd (for fail2ban) removed too, on its own: another program
    # that needs it keeps only it, not the rest of the seedbox
    declare -f seedbox_uninstall | grep -qx ' *apt_purge python3-systemd;\?' \
        && ! declare -f seedbox_uninstall | grep 'apt_purge transmission-daemon' | grep -q python3-systemd || return 1
    SEEDBOX_USER=lancelot
    SEEDBOX_DATA_DIR="$WORK/no-data"
    id() { return 0; }
    pkill() { :; }
    userdel() { echo "userdel: the user is gone"; }
    : >"$APP_LOG"
    seedbox_delete_user || return 1
    grep -A2 '· Deleting the user lancelot$' "$APP_LOG" | grep -q "userdel: the user is gone"
)

# -----------------------------------------------------------------------------------

# install -o/-g and runuser without root: the owner is left as it is
install_without_owner() {
    install() {
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
    runuser() {
        echo "runuser $2" >>"$WORK/runuser-calls"
        while [[ $1 != -- ]]; do shift; done
        shift
        "$@"
    }
}

# A backup of Ubuntu 26.04 (Transmission 4.1) restored on Debian 12
# (Transmission 3): the torrents did not start (Transmission 3 does not read
# the progress files of Transmission 4). They now go back through watch/,
# readable by Transmission, whatever the version; the list of the server is
# replaced; the settings of the backup put back.
restore_torrents_through_watch() (
    load
    install_without_owner
    local backup="$WORK/tr-restore/x" source
    rm -rf "$WORK/tr-restore" "$WORK/tr-data" "$WORK/tr-state"
    TRANSMISSION_STATE_DIR="$WORK/tr-state"
    SEEDBOX_DATA_DIR="$WORK/tr-data"
    source="$backup$TRANSMISSION_STATE_DIR"
    mkdir -p "$SEEDBOX_DATA_DIR/watch" "$TRANSMISSION_STATE_DIR/torrents" "$TRANSMISSION_STATE_DIR/resume" \
        "$source/torrents" "$source/resume" "$backup/etc/transmission-daemon"
    transmission_settings_file() { echo "$WORK/tr-settings.json"; }
    printf '{"server": true}\n' >"$WORK/tr-settings.json"
    # the list of this server
    touch "$TRANSMISSION_STATE_DIR/torrents/old.0123456789abcdef.torrent" "$TRANSMISSION_STATE_DIR/resume/old.0123456789abcdef.resume"
    # names of Transmission 4 and of Transmission 3, a link that has no place there
    printf 'd4:infod4:name1:aee' >"$source/torrents/7acf8fb590b2060dd9c3146ef770169d593433b0.torrent"
    printf 'd4:infod4:name1:bee' >"$source/torrents/debian.0123456789abcdef.torrent"
    ln -s /etc/passwd "$source/torrents/link.torrent"
    printf 'de' >"$source/resume/7acf8fb590b2060dd9c3146ef770169d593433b0.resume"
    printf '{"backup": true}\n' >"$backup/etc/transmission-daemon/settings.json"
    chmod 600 "$source/torrents/"*.torrent
    # a link put in watch/ under the name of a torrent of the backup: replaced,
    # never followed
    echo keep >"$WORK/tr-victim"
    ln -s "$WORK/tr-victim" "$SEEDBOX_DATA_DIR/watch/debian.0123456789abcdef.torrent"
    : >"$WORK/runuser-calls"
    restore_transmission_state "$backup" >"$WORK/tr-restore.out" 2>&1 || return 1
    cat "$WORK/tr-restore.out"
    # written by the account of Transmission, never by root (watch/ is the SFTP user's too)
    [[ $(sort -u "$WORK/runuser-calls") == "runuser $TRANSMISSION_USER" ]] || return 1
    [[ -f $SEEDBOX_DATA_DIR/watch/7acf8fb590b2060dd9c3146ef770169d593433b0.torrent && -f $SEEDBOX_DATA_DIR/watch/debian.0123456789abcdef.torrent ]] \
        && [[ ! -e $SEEDBOX_DATA_DIR/watch/link.torrent ]] || return 1
    # readable by Transmission, whatever the rights in the backup
    [[ $(stat -c %a "$SEEDBOX_DATA_DIR/watch/debian.0123456789abcdef.torrent") == 644 ]] || return 1
    [[ $(<"$WORK/tr-victim") == keep && ! -L $SEEDBOX_DATA_DIR/watch/debian.0123456789abcdef.torrent ]] || return 1
    [[ -z $(find "$SEEDBOX_DATA_DIR/watch" -name '*.torrent.*') ]] || return 1
    # the list of the server replaced, no progress put back, the settings of the backup
    [[ ! -e $TRANSMISSION_STATE_DIR/torrents && ! -e $TRANSMISSION_STATE_DIR/resume ]] || return 1
    [[ $(<"$WORK/tr-settings.json") == '{"backup": true}' ]] || return 1
    grep -q "Torrents put back: 2 (through $SEEDBOX_DATA_DIR/watch/)." "$WORK/tr-restore.out" \
        && grep -q "Not kept: pauses" "$WORK/tr-restore.out" \
        && grep -q "· Putting the torrents of the backup back through" "$APP_LOG" || return 1
    # a backup without the state of Transmission: the list of the server stays
    mkdir -p "$TRANSMISSION_STATE_DIR/torrents"
    touch "$TRANSMISSION_STATE_DIR/torrents/kept.torrent"
    rm -rf "$WORK/tr-restore2"
    mkdir -p "$WORK/tr-restore2/x"
    restore_transmission_state "$WORK/tr-restore2/x" >/dev/null 2>&1 || return 1
    [[ -e $TRANSMISSION_STATE_DIR/torrents/kept.torrent ]]
)

# A restore stops Transmission once: its torrents and settings go back while
# it is stopped for its settings, then it starts once
restore_stops_transmission_once() (
    load
    TRANSMISSION_DROPIN="$WORK/dropin-once/seedtunnel.conf"
    SEEDBOX_DATA_DIR="$WORK/data"
    printf '{"old": true}\n' >"$WORK/once-settings.json"
    : >"$WORK/once-calls"
    transmission_settings_file() { echo "$WORK/once-settings.json"; }
    transmission_desired_settings() { echo '{"new": true}'; }
    diskguard_stopped() { return 1; }
    chown() { :; }
    systemctl() { echo "systemctl $*" >>"$WORK/once-calls"; }
    restore_transmission_state() { echo "restore $1" >>"$WORK/once-calls"; }
    TRANSMISSION_RESTORE_FROM="$WORK/backup-x"
    seedbox_apply_transmission >"$WORK/once.out" 2>&1 || return 1
    cat "$WORK/once-calls"
    [[ $(grep -c "systemctl stop transmission-daemon" "$WORK/once-calls") == 1 ]] \
        && [[ $(grep -c "systemctl restart transmission-daemon" "$WORK/once-calls") == 1 ]] \
        && grep -qx "restore $WORK/backup-x" "$WORK/once-calls" && [[ -z $TRANSMISSION_RESTORE_FROM ]] || return 1
    # the stop comes before the restore, the start after
    [[ $(grep -n . "$WORK/once-calls" | grep -E 'stop|restore|restart' | cut -d: -f2- | tr '\n' '|') == "systemctl stop transmission-daemon|restore $WORK/backup-x|systemctl restart transmission-daemon|" ]] || return 1
    # without a restore: nothing restored
    : >"$WORK/once-calls"
    seedbox_apply_transmission >/dev/null 2>&1 || return 1
    ! grep -q restore "$WORK/once-calls"
)

# A .torrent of watch/ that Transmission cannot read (copied by root with the
# rights of its original) was never added, without a word: the diagnostics say it
doctor_sees_watch_unreadable() (
    load
    rm -rf "$WORK/w-data"
    SEEDBOX_DATA_DIR="$WORK/w-data"
    TRANSMISSION_USER=transmission-test
    mkdir -p "$SEEDBOX_DATA_DIR/watch"
    install -m 644 /dev/null "$SEEDBOX_DATA_DIR/watch/fine.torrent"
    doctor_watch_unreadable >"$WORK/w.out" 2>&1
    [[ ! -s $WORK/w.out ]] || return 1
    install -m 600 /dev/null "$SEEDBOX_DATA_DIR/watch/root.torrent"
    install -m 640 /dev/null "$SEEDBOX_DATA_DIR/watch/group.torrent"
    ln -s /etc/shadow "$SEEDBOX_DATA_DIR/watch/link.torrent"
    doctor_watch_unreadable >"$WORK/w.out" 2>&1
    cat "$WORK/w.out"
    grep -q "2 .torrent file(s) of $SEEDBOX_DATA_DIR/watch/ unreadable by Transmission" "$WORK/w.out" \
        && grep -q "add them again through the web interface or by SFTP" "$WORK/w.out" && ! grep -q "chgrp\|chmod" "$WORK/w.out"
)

# Turning the weekly backup off deleted its passphrase without a word: now
# said, and « no » by default (menu), --yes needed without a terminal
weekly_backup_off_asked() (
    load
    : >"$WORK/off-calls"
    clear() { :; }
    backup_auto_enabled() { return 0; }
    backup_auto_disable() { echo "disable" >>"$WORK/off-calls"; }
    pause() { :; }
    # menu: « no »
    INTERACTIVE=1
    confirm() {
        echo "asked: $1" >>"$WORK/off-calls"
        return 1
    }
    backup_menu_weekly >"$WORK/off.out" 2>&1
    cat "$WORK/off.out" "$WORK/off-calls"
    grep -q "The passphrase saved on the server is deleted" "$WORK/off.out" \
        && grep -qx "asked: Turn the weekly backup off?" "$WORK/off-calls" && ! grep -q disable "$WORK/off-calls" || return 1
    # « yes »: turned off
    confirm() { return 0; }
    backup_menu_weekly >/dev/null 2>&1
    grep -qx disable "$WORK/off-calls" || return 1
    # command without a terminal nor --yes: refused, nothing changed (the
    # real « confirm » again)
    load
    backup_auto_enabled() { return 0; }
    backup_auto_disable() { echo "disable" >>"$WORK/off-calls"; }
    : >"$WORK/off-calls"
    INTERACTIVE=0
    OPT_YES=0
    if (backup_cli auto off) >"$WORK/off.out" 2>&1 </dev/null; then return 1; fi
    grep -q -- "--yes" "$WORK/off.out" && ! grep -q disable "$WORK/off-calls" || return 1
    OPT_YES=1
    (backup_cli auto off) >/dev/null 2>&1 </dev/null && grep -qx disable "$WORK/off-calls" || return 1
    # already off, nothing of it left: said, nothing asked nor done (even
    # without --yes)
    backup_auto_enabled() { return 1; }
    BACKUP_TIMER="$WORK/off-none/seedtunnel-backup.timer"
    BACKUP_PASSPHRASE_FILE="$WORK/off-none/backup.passphrase"
    : >"$WORK/off-calls"
    OPT_YES=0
    (backup_cli auto off) >"$WORK/off.out" 2>&1 </dev/null || return 1
    grep -q "The weekly backup is already off: nothing to do." "$WORK/off.out" && [[ ! -s $WORK/off-calls ]] || return 1
    # removing the VPN and the seedbox turns it off without a question
    declare -f backup_auto_stop_if_unused | grep -q 'backup_auto_disable;'
)

# The last line says the passphrase saved on the server was deleted (only when
# there was one: a restore turns off a weekly backup that had none)
weekly_backup_off_says_passphrase_deleted() (
    load
    BACKUP_SERVICE="$WORK/off-units/seedtunnel-backup.service"
    BACKUP_TIMER="$WORK/off-units/seedtunnel-backup.timer"
    BACKUP_PASSPHRASE_FILE="$WORK/off-units/backup.passphrase"
    mkdir -p "$WORK/off-units"
    systemctl() { :; }
    echo "a passphrase" >"$BACKUP_PASSPHRASE_FILE"
    backup_auto_disable >"$WORK/off-last.out" 2>&1 || return 1
    cat "$WORK/off-last.out"
    grep -q "Weekly backup off, its passphrase deleted from the server" "$WORK/off-last.out" \
        && [[ ! -e $BACKUP_PASSPHRASE_FILE ]] || return 1
    backup_auto_disable >"$WORK/off-last.out" 2>&1 || return 1
    grep -q "Weekly backup off (the existing backups are kept in" "$WORK/off-last.out" \
        && ! grep -q "passphrase" "$WORK/off-last.out"
)

# =============================================================================
# Security: a backup made by someone else, Transmission, links, set -e
# =============================================================================

# --- An action that fails halfway stops (set -e in force) -------------------------

# The copy of the settings fails during a restore from the menu: the restore
# stops, says how to go back, and its marker stays (never « Restore finished »).
# In a process of its own (strict): inside a test, « set -e » is ignored.
restore_stops_when_a_step_fails() (
    local out
    out=$(strict "$(declare -f restore_archive_load restore_archive_make restore_weekly_load)"'
        restore_weekly_load copyfail
        RESTORE_MARKER="$APP_STATE_DIR.restore-unfinished"
        echo "VPN_PORT=1194" >"$APP_STATE_DIR/vpn.conf"
        backup_pick_file() { printf -v "$1" "%s" "$WORK/copyfail.enc"; }
        pause() { :; }
        cp() {
            if [[ $1 == -a* ]]; then return 1; fi
            command cp "$@"
        }
        ui_action backup_menu_restore
        if [[ -s $RESTORE_MARKER ]]; then echo "marker kept"; fi' 2>&1)
    echo "$out"
    [[ $out != *"Restore finished"* && $out == *"did not finish"* && $out == *"marker kept"* ]]
)

# No action that changes the server is called in an « if », or before « || »
# or « && »: bash would ignore « set -e » inside it. No « ( … ) || exit »
# either (in_subshell instead).
actions_never_called_in_a_condition() (
    local actions found
    actions='restore_main|restore_transmission_state|backup_main|backup_auto_enable|backup_auto_disable_asked|backup_auto_disable'
    actions+='|vpn_change_settings|vpn_change_dns|vpn_set_dns|vpn_apply|apply_main|firewall_enable|firewall_refresh'
    actions+='|seedbox_change_credentials|seedbox_change_domain|seedbox_set_credentials|seedbox_apply|seedbox_apply_https'
    actions+='|seedbox_apply_sftp|seedbox_apply_transmission|sftp_key_generate'
    found=$(grep -nE "^[^#]*((\b(if|elif|while|until)\s+!?\s*)($actions)\b|\b($actions)\b[^#]*(\|\||&&)|(\|\||&&)\s*!?\s*($actions)\b)|^\s*\)\s*(\|\||&&)" \
        "$ROOT/seedtunnel.sh" "$ROOT"/lib/*.sh || true)
    [[ -z $found ]] || {
        echo "$found"
        return 1
    }
)

# --- A backup made by someone else cannot run anything ----------------------------

# A settings file with a name seedtunnel never writes (PATH, APP_DIR…): refused
restore_refuses_other_names() (
    restore_archive_load names
    printf 'VPN_PORT=51820\nPATH=/etc/seedtunnel/bin\n' >"$RESTORE_ROOT/etc/seedtunnel/vpn.conf"
    restore_archive_make names
    if (restore_main "$WORK/names.enc") >"$WORK/names.out" 2>&1; then return 1; fi
    cat "$WORK/names.out"
    grep -q "vpn.conf holds something else than settings" "$WORK/names.out" || return 1
    # another settings file of its own: refused too
    restore_archive_load names2
    echo "X=1" >"$RESTORE_ROOT/etc/seedtunnel/other.conf"
    restore_archive_make names2
    if (restore_main "$WORK/names2.enc") >"$WORK/names2.out" 2>&1; then return 1; fi
    grep -q "other.conf holds something else than settings" "$WORK/names2.out"
)

# Values that seedtunnel would have refused at an installation: refused
restore_refuses_unexpected_values() (
    local case
    for case in "seedbox.conf:SEEDBOX_USER=../lancelot:SEEDBOX_USER" "seedbox.conf:SEEDBOX_DATA_DIR=/etc:SEEDBOX_DATA_DIR" \
        "vpn.conf:VPN_PORT=99999:VPN_PORT" "vpn.conf:VPN_DNS=9.9.9.9\\ 1.1.1.1x:VPN_DNS" \
        "firewall.conf:FIREWALL_ENABLED=yes:FIREWALL_ENABLED" "vpn/clients/laptop.env:CLIENT_NUMBER=900:CLIENT_NUMBER"; do
        restore_archive_load values
        printf '%s\n' "${case#*:}" | cut -d: -f1 >>"$RESTORE_ROOT/etc/seedtunnel/${case%%:*}"
        restore_archive_make values
        if (restore_main "$WORK/values.enc") >"$WORK/values.out" 2>&1; then
            echo "accepted: $case"
            return 1
        fi
        grep -q "unexpected value of ${case##*:} in etc/seedtunnel/${case%%:*}" "$WORK/values.out" || {
            echo "$case"
            cat "$WORK/values.out"
            return 1
        }
    done
    # the key of the VPN server on two lines (the second would go into wg0.conf)
    restore_archive_load values
    printf 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\nPostUp = touch /tmp/x\n' >"$RESTORE_ROOT/etc/seedtunnel/vpn/server.key"
    restore_archive_make values
    if (restore_main "$WORK/values.enc") >"$WORK/values.out" 2>&1; then return 1; fi
    grep -q "unexpected value of PrivateKey in etc/seedtunnel/vpn/server.key" "$WORK/values.out"
)

# A file that could be run (execute, setuid bit): refused; the archive goes to
# root whatever its owners say
restore_refuses_programs() (
    restore_archive_load programs
    mkdir -p "$RESTORE_ROOT/etc/seedtunnel/bin"
    printf '#!/bin/sh\n' >"$RESTORE_ROOT/etc/seedtunnel/bin/ip"
    chmod 755 "$RESTORE_ROOT/etc/seedtunnel/bin/ip"
    restore_archive_make programs
    if (restore_main "$WORK/programs.enc") >"$WORK/programs.out" 2>&1; then return 1; fi
    cat "$WORK/programs.out"
    grep -q 'Archive refused: "etc/seedtunnel/bin/ip" is a link, a program or a special file' "$WORK/programs.out" || return 1
    declare -f restore_main | grep -q -- "--no-same-owner"
)

# A client of the VPN named as no client can be (its name goes into wg0.conf:
# after a line break, « PostUp = … » would run as root), a control character
# in any name: refused, said as in the archive, nothing restored. A file of
# another kind in clients/ (left by a write cut short) does not matter.
restore_refuses_bad_names() (
    local name expected
    for name in $'vpn/clients/x\n[Interface]\nPostUp = touch pwned\n#.env' "vpn/clients/my phone.env" \
        "vpn/clients/a.b.conf" "vpn/clients/sixteen-letters-.env" $'ssl/a\tb.key'; do
        restore_archive_load badname
        mkdir -p "$RESTORE_ROOT/etc/seedtunnel/${name%/*}"
        cp "$RESTORE_ROOT/etc/seedtunnel/vpn/clients/laptop.env" "$RESTORE_ROOT/etc/seedtunnel/$name"
        restore_archive_make badname
        if (restore_main "$WORK/badname.enc") >"$WORK/badname.out" 2>&1; then
            echo "accepted: $name"
            return 1
        fi
        expected="Archive refused: unexpected path \"$(printf '%q' "etc/seedtunnel/$name")\""
        grep -qF "$expected" "$WORK/badname.out" && [[ -z $(ls -A "$APP_STATE_DIR") ]] || {
            echo "expected: $expected"
            cat "$WORK/badname.out"
            return 1
        }
    done
    # names seedtunnel gives, and a temporary file left behind: restored
    restore_archive_load goodname
    cp "$RESTORE_ROOT/etc/seedtunnel/vpn/clients/laptop.env" "$RESTORE_ROOT/etc/seedtunnel/vpn/clients/Phone_2-b.env"
    echo x >"$RESTORE_ROOT/etc/seedtunnel/vpn/clients/laptop.conf.Ab12Cd"
    restore_archive_make goodname
    (restore_main "$WORK/goodname.enc") >"$WORK/goodname.out" 2>&1
    ! grep -q "refused" "$WORK/goodname.out" && grep -q "The backup contains" "$WORK/goodname.out"
)

# The renewal file of the certificate: no command but the reload of nginx, the
# paths of seedtunnel only
restore_refuses_letsencrypt_commands() (
    local line renewal
    for line in "renew_hook = touch /tmp/x" "post_hook = systemctl reload nginx" "authenticator = manual" \
        "archive_dir = /etc/cron.d" "webroot_path = /etc/sudoers.d," "logs_dir = /etc/cron.d"; do
        restore_archive_load le-hook
        renewal="$RESTORE_ROOT/etc/letsencrypt/renewal/seedtunnel.conf"
        mkdir -p "${renewal%/*}"
        printf 'version = 2.9.0\narchive_dir = %s/archive/seedtunnel\n[renewalparams]\nauthenticator = webroot\nwebroot_path = /var/www/letsencrypt,\nrenew_hook = systemctl reload nginx\n%s\n' \
            "$LETSENCRYPT_ROOT" "$line" >"$renewal"
        restore_archive_make le-hook
        if (restore_main "$WORK/le-hook.enc") >"$WORK/le-hook.out" 2>&1; then
            echo "accepted: $line"
            return 1
        fi
        grep -q "unexpected value of ${line%% *} in etc/letsencrypt/renewal/seedtunnel.conf" "$WORK/le-hook.out" || {
            cat "$WORK/le-hook.out"
            return 1
        }
    done
    # the renewal file as certbot writes it for seedtunnel: accepted
    restore_archive_load le-ok
    renewal="$RESTORE_ROOT/etc/letsencrypt/renewal/seedtunnel.conf"
    mkdir -p "${renewal%/*}"
    printf '%s\n' "# renew_before_expiry = 30 days" "version = 2.9.0" "archive_dir = $LETSENCRYPT_ROOT/archive/seedtunnel" \
        "cert = $LETSENCRYPT_ROOT/live/seedtunnel/cert.pem" "privkey = $LETSENCRYPT_ROOT/live/seedtunnel/privkey.pem" \
        "chain = $LETSENCRYPT_ROOT/live/seedtunnel/chain.pem" "fullchain = $LETSENCRYPT_ROOT/live/seedtunnel/fullchain.pem" \
        "" "# Options used in the renewal process" "[renewalparams]" "account = 0123abcd" "authenticator = webroot" \
        "webroot_path = /var/www/letsencrypt," "server = https://acme-v02.api.letsencrypt.org/directory" \
        "key_type = ecdsa" "renew_hook = systemctl reload nginx" "[[webroot_map]]" "seedbox.example.org = /var/www/letsencrypt" \
        >"$renewal"
    restore_archive_make le-ok
    (restore_main "$WORK/le-ok.enc") >"$WORK/le-ok.out" 2>&1
    cat "$WORK/le-ok.out"
    ! grep -q "refused" "$WORK/le-ok.out" && grep -q "The backup contains" "$WORK/le-ok.out"
)

# Only the certificate of seedtunnel and the account go back: not the other
# certificates of the backup, nor its renewal-hooks
restore_letsencrypt_only_seedtunnel() (
    load
    local from="$WORK/le-from"
    LETSENCRYPT_ROOT="$WORK/le-root"
    rm -rf "$from" "$LETSENCRYPT_ROOT"
    mkdir -p "$from/live/seedtunnel" "$from/archive/seedtunnel" "$from/renewal" "$from/accounts/acme" \
        "$from/live/other" "$from/renewal-hooks/deploy"
    echo cert >"$from/archive/seedtunnel/cert1.pem"
    ln -s ../../archive/seedtunnel/cert1.pem "$from/live/seedtunnel/cert.pem"
    echo conf >"$from/renewal/seedtunnel.conf"
    echo conf >"$from/renewal/other.conf"
    echo key >"$from/accounts/acme/private_key.json"
    echo x >"$from/renewal-hooks/deploy/x.sh"
    restore_letsencrypt "$from"
    [[ -L $LETSENCRYPT_ROOT/live/seedtunnel/cert.pem && $(<"$LETSENCRYPT_ROOT/live/seedtunnel/cert.pem") == cert ]] || return 1
    [[ -f $LETSENCRYPT_ROOT/renewal/seedtunnel.conf && -f $LETSENCRYPT_ROOT/accounts/acme/private_key.json ]] || return 1
    [[ ! -e $LETSENCRYPT_ROOT/live/other && ! -e $LETSENCRYPT_ROOT/renewal/other.conf && ! -e $LETSENCRYPT_ROOT/renewal-hooks ]] || return 1
    [[ $(stat -c %a "$LETSENCRYPT_ROOT/live") == 700 && $(stat -c %a "$LETSENCRYPT_ROOT/renewal") == 755 ]]
)

# wg0.conf takes the first line of the key of the server only
vpn_server_key_one_line() (
    load
    VPN_STATE_DIR="$WORK/vpn-key"
    VPN_CLIENTS_DIR="$VPN_STATE_DIR/clients"
    VPN_PORT=51820
    mkdir -p "$VPN_CLIENTS_DIR"
    printf 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\nPostUp = touch /tmp/x\n' >"$VPN_STATE_DIR/server.key"
    local conf
    conf=$(vpn_generate_server_conf)
    [[ $conf == *"PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="* && $conf != *PostUp* ]]
)

# A file in clients/ named as no client can be (put there by hand): no client,
# nothing of it in wg0.conf nor in the NAT rules, nor in the lists
vpn_ignores_bad_client_names() (
    load
    VPN_STATE_DIR="$WORK/vpn-names"
    VPN_CLIENTS_DIR="$VPN_STATE_DIR/clients"
    VPN_PORT=51820
    VPN_OUT_INTERFACE=eth0
    rm -rf "$VPN_STATE_DIR"
    mkdir -p "$VPN_CLIENTS_DIR"
    echo "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=" >"$VPN_STATE_DIR/server.key"
    local name conf rules
    for name in laptop $'x\n[Interface]\nPostUp = touch pwned\n#' "my phone"; do
        (
            CLIENT_NUMBER=$((${#name} % 200 + 1))
            CLIENT_PUBLIC_KEY="yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
            CLIENT_PRESHARED_KEY=$CLIENT_PUBLIC_KEY
            state_write "$VPN_CLIENTS_DIR/$name.env" CLIENT_NUMBER CLIENT_PUBLIC_KEY CLIENT_PRESHARED_KEY
        )
    done
    mkdir "$VPN_CLIENTS_DIR/folder.env"
    conf=$(vpn_generate_server_conf) && rules=$(vpn_generate_nat_rules) || return 1
    [[ $conf == *"# client: laptop"* && $conf != *PostUp* && $conf != *"my phone"* && $(grep -c '^\[Interface\]' <<<"$conf") == 1 ]] || {
        echo "$conf"
        return 1
    }
    [[ $rules == *'# client "laptop"'* && $rules != *PostUp* && $rules != *"my phone"* ]] || return 1
    [[ $(vpn_client_names) == laptop && $(vpn_count_clients) == 1 ]]
)

# --- One-time links: the token in no argument (ps, systemctl status) -------------

share_token_not_in_arguments() (
    share_load token
    local out token
    : >"$WORK/share-args"
    systemd-run() { printf '%s\n' "$*" >>"$WORK/share-args"; }
    pgrep() { [[ $* == "-P 4242 -x inotifywait" ]]; }
    out=$(share_create "$WORK/to-share" phone.conf "VPN" "<li>x</li>" "note" 2>&1) || {
        echo "$out"
        return 1
    }
    token=$(grep -oE '/share/[0-9a-f]{32}' <<<"$out" | cut -d/ -f3)
    [[ -n $token ]] && ! grep -q "${token:0:8}" "$WORK/share-args" || {
        cat "$WORK/share-args"
        return 1
    }
    # the watcher, and the timer that deletes the link at the end anyway
    grep -q -- "--on-active=$((SHARE_LIFETIME + 120)) " "$WORK/share-args" && (($(grep -c -- "--unit=seedtunnel-share-" "$WORK/share-args") == 2)) || return 1
    # what the watcher needs: in files of root only, the token inside
    local job
    job=$(find "$SHARE_DIR.jobs" -type f ! -name '*.stop')
    [[ -n $job && $(stat -c %a "$job") == 600 && $(stat -c %a "$job.stop") == 600 ]] && grep -q "$token" "$job" "$job.stop" \
        && [[ $(stat -c %a "$SHARE_DIR") == 710 && $(stat -c %a "$SHARE_DIR.jobs") == 700 ]]
)

# The job of a watcher: the link deleted at the end (the stop script, run by
# systemd whatever ends the watcher, deletes its files and itself)
share_stop_script_cleans_up() (
    share_load stop
    pgrep() { return 0; }
    share_create "$WORK/to-share" phone.conf "VPN" "" "note" >/dev/null 2>&1 || return 1
    local job
    job=$(find "$SHARE_DIR.jobs" -type f ! -name '*.stop')
    [[ -n $(ls -A "$SHARE_DIR") ]] || return 1
    bash "$job.stop"
    [[ -z $(ls -A "$SHARE_DIR") && -z $(ls -A "$SHARE_DIR.jobs") ]]
)

# --- Transmission: root never writes where its account can lead it ---------------

# A link put beside its settings by the account of Transmission is never
# followed by root: the settings are written by that account
transmission_settings_never_through_a_link() (
    load
    install_without_owner
    local dir="$WORK/tr-link"
    rm -rf "$dir"
    mkdir -p "$dir"
    echo keep >"$dir/victim"
    printf '{"old": true}\n' >"$dir/settings.json"
    ln -s "$dir/victim" "$dir/settings.json.tmp"
    transmission_settings_file() { echo "$dir/settings.json"; }
    transmission_desired_settings() { echo '{"new": true}'; }
    transmission_knows_transports() { return 1; }
    TRANSMISSION_DROPIN="$dir/dropin/seedtunnel.conf"
    SEEDBOX_DATA_DIR="$WORK/data"
    diskguard_stopped() { return 1; }
    systemctl() { :; }
    # the tests do not run as root
    chown() { :; }
    : >"$WORK/runuser-calls"
    seedbox_apply_transmission >"$WORK/tr-link.out" 2>&1 || {
        cat "$WORK/tr-link.out"
        return 1
    }
    [[ $(<"$dir/victim") == keep && $(jq -c . "$dir/settings.json") == '{"old":true,"new":true}' ]] || return 1
    grep -qx "runuser $TRANSMISSION_USER" "$WORK/runuser-calls" && [[ -z $(find "$APP_STATE_DIR" -name '.transmission-settings.*') ]]
)

# Its settings: the file of /etc (link of Debian) or a file of its own, never
# a file elsewhere that its link would lead to
transmission_settings_link_to_etc_only() (
    load
    local dir="$WORK/tr-where"
    rm -rf "$dir"
    mkdir -p "$dir/state" "$dir/etc"
    TRANSMISSION_STATE_DIR="$dir/state"
    TRANSMISSION_ETC_SETTINGS="$dir/etc/settings.json"
    [[ $(transmission_settings_file) == "$TRANSMISSION_ETC_SETTINGS" ]] || return 1
    echo '{}' >"$TRANSMISSION_ETC_SETTINGS"
    ln -s "$TRANSMISSION_ETC_SETTINGS" "$dir/state/settings.json"
    [[ $(transmission_settings_file) == "$TRANSMISSION_ETC_SETTINGS" ]] || return 1
    rm "$dir/state/settings.json"
    echo '{}' >"$dir/state/settings.json"
    [[ $(transmission_settings_file) == "$dir/state/settings.json" ]] || return 1
    # a link elsewhere, or the file of /etc made a link elsewhere: refused, said
    rm "$dir/state/settings.json"
    ln -s /etc/shadow "$dir/state/settings.json"
    if transmission_settings_file >"$WORK/where.out" 2>&1; then return 1; fi
    grep -q "point somewhere unexpected" "$WORK/where.out" || return 1
    rm "$dir/state/settings.json"
    ln -s "$TRANSMISSION_ETC_SETTINGS" "$dir/state/settings.json"
    rm "$TRANSMISSION_ETC_SETTINGS"
    ln -s /etc/shadow "$TRANSMISSION_ETC_SETTINGS"
    ! transmission_settings_file >/dev/null 2>&1
)

# --- DNS of the clients: one line of addresses -------------------------------------

dns_one_line_of_addresses() (
    load
    ! vpn_is_valid_dns $'9.9.9.9\n1.1.1.1' && ! vpn_is_valid_dns $'9.9.9.9\nPostUp = touch /tmp/x' \
        && ! vpn_is_valid_dns '9.9. 9.9' && ! vpn_is_valid_dns $'9.9.9.9\t' || return 1
    vpn_is_valid_dns '9.9.9.9, 1.1.1.1' && vpn_is_valid_dns ' 2620:fe::fe ,9.9.9.9 ' || return 1
    [[ $(vpn_dns_normalize ' 2620:fe::fe ,9.9.9.9 ') == "2620:fe::fe, 9.9.9.9" ]]
)

# A backup that could not be restored is refused when it is made
backup_refused_if_it_could_not_be_restored() (
    backup_load
    # a state folder of its own: the others stay as they are for the next tests
    APP_STATE_DIR="$WORK/unrestorable-state"
    mkdir -p "$APP_STATE_DIR"
    printf '%s\n' "VPN_DNS=\$'9.9.9.9\\n1.1.1.1'" >"$APP_STATE_DIR/vpn.conf"
    if (backup_write "$BACKUP_DIR/x.tar.gz.enc") </dev/null >"$WORK/unrestorable.out" 2>&1; then return 1; fi
    cat "$WORK/unrestorable.out"
    grep -q "This backup could not be restored: .*vpn.conf holds something else than settings" "$WORK/unrestorable.out" \
        && [[ -z $(ls -A "$BACKUP_DIR" 2>/dev/null) ]]
)

# A file changed while tar reads it (progress of Transmission): no failure
backup_file_changed_meanwhile_is_no_failure() (
    backup_load
    tar() {
        command tar "$@"
        if [[ $1 == -czf ]]; then return 1; fi
    }
    backup_write "$BACKUP_DIR/changed.tar.gz.enc" </dev/null >/dev/null 2>&1 && [[ -s $BACKUP_DIR/changed.tar.gz.enc ]]
)

# --- Firewall: loaded rules older than their file are loaded again ----------------

firewall_refresh_reloads_stale_rules() (
    load
    FIREWALL_UNIT="$WORK/fw-stale.service"
    FIREWALL_CONF_FILE="$WORK/fw-stale.conf"
    FIREWALL_RULES="$WORK/fw-stale.nft"
    echo FIREWALL_ENABLED=1 >"$FIREWALL_CONF_FILE"
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    VPN_PORT=51820
    firewall_ssh_ports() { printf 22; }
    systemctl() { return 0; }
    # the tests do not run as root
    chown() { :; }
    : >"$WORK/fw-stale-calls"
    nft() {
        if [[ $1 == list ]]; then
            printf 'table inet seedtunnel_fw {\n type filter hook input priority filter; policy drop;\n tcp dport { 22 } accept\n}\n'
        else
            echo "nft $*" >>"$WORK/fw-stale-calls"
        fi
    }
    firewall_generate_rules >"$FIREWALL_RULES"
    firewall_refresh >/dev/null 2>&1
    cat "$WORK/fw-stale-calls"
    grep -q "^nft -f" "$WORK/fw-stale-calls"
)

# --- Restore on a new server: the diagnostic speaks of this server ----------------

restore_leaves_the_marks_of_the_other_server() (
    restore_weekly_load marks
    # the backup: a weekly backup on for 200 days, a download 3 days ago
    printf 'old passphrase\n' >"$RESTORE_ROOT/etc/seedtunnel/backup.passphrase"
    chmod 600 "$RESTORE_ROOT/etc/seedtunnel/backup.passphrase"
    touch -d '200 days ago' "$RESTORE_ROOT/etc/seedtunnel/backup.passphrase"
    touch -d '3 days ago' "$RESTORE_ROOT/etc/seedtunnel/backup.downloaded"
    restore_archive_make marks
    # this server: a download yesterday
    echo "VPN_PORT=1194" >"$APP_STATE_DIR/vpn.conf"
    touch -d '1 day ago' "$APP_STATE_DIR/backup.downloaded"
    restore_main "$WORK/marks.enc" >"$WORK/marks.out" 2>&1 || {
        cat "$WORK/marks.out"
        return 1
    }
    [[ $(file_age_days "$APP_STATE_DIR/backup.downloaded") == 1 && $(file_age_days "$APP_STATE_DIR/backup.passphrase") == 0 ]] || return 1
    # without a download on this server: none
    restore_weekly_load marks2
    touch -d '3 days ago' "$RESTORE_ROOT/etc/seedtunnel/backup.downloaded"
    restore_archive_make marks2
    restore_main "$WORK/marks2.enc" >"$WORK/marks2.out" 2>&1 || return 1
    [[ ! -e $APP_STATE_DIR/backup.downloaded ]]
)

# --- Report: the names used before and the administrators replaced too ----------

report_replaces_former_names() (
    report_load
    cat >>"$WORK/report.txt" <<'EOF'
=== 2026-11-06 19:20:00 · Creating the user arthur-dupont
$ useradd --no-create-home --home-dir / --shell /usr/sbin/nologin --user-group --groups debian-transmission --comment seedtunnel seedbox arthur-dupont
=== 2026-11-06 19:21:00 · Certificat Let's Encrypt pour ancien.famille-dupont.fr
$ openssl req -x509 -newkey ec -subj /CN=ancien.famille-dupont.fr -addext subjectAltName=DNS:ancien.famille-dupont.fr
 jean.martin @ session #1: bash[1951], sshd-session[1821,1946], sudo[2403,2405]
 jean.martin @ user manager service: systemd[1273]
 gauvain @ user manager: (sd-pam)[1831]
/root/seedtunnel-old-box-20261101-101010.tar.gz.enc
Hit:2 http://nova.clouds.archive.ubuntu.com/ubuntu noble InRelease
perceval ran it
EOF
    SUDO_USER=perceval
    who() { :; }
    report_anonymize "$WORK/report.txt"
    cat "$WORK/report.txt"
    ! grep -q 'famille-dupont\|arthur-dupont\|jean.martin\|gauvain\|perceval\|old-box' "$WORK/report.txt" || return 1
    grep -q "<former-domain>" "$WORK/report.txt" && grep -q "<former-sftp-user>" "$WORK/report.txt" \
        && grep -q "^ <admin> @ session #1" "$WORK/report.txt" && grep -qF " <admin> @ user manager: (sd-pam)[1831]" "$WORK/report.txt" \
        && grep -qF " <admin> @ user manager service: systemd[1273]" "$WORK/report.txt" && grep -q "seedtunnel-<server>-20261101-101010" "$WORK/report.txt" \
        && grep -q "nova.clouds.archive.ubuntu.com/ubuntu noble" "$WORK/report.txt" && grep -q "debian-transmission" "$WORK/report.txt"
)

# Seen on Debian 13: while WinSCP is connected, « who » lists the SFTP account
# too; it keeps its own name, not <admin>. The addresses of the DNS services
# of the menu stay (the same for everyone), one typed by hand is replaced.
report_sftp_account_and_dns() (
    report_load
    cat >>"$WORK/report.txt" <<'EOF'
=== 2026-11-12 11:20:49 · Creating the user lancelot
=== 2026-11-12 12:10:55 · Download link for seedbox-lancelot.ppk
=== 2026-11-12 12:05:50 · Changing the DNS of the clients: Quad9 · 9.9.9.9, 149.112.112.112
=== 2026-11-12 12:06:10 · Changing the DNS of the clients: AdGuard · 94.140.14.14, 94.140.15.15
=== 2026-11-12 12:06:30 · Changing the DNS of the clients: 1.1.1.1, 86.54.11.201
=== 2026-11-12 12:07:00 · Changing the DNS of the clients: 198.51.100.53
EOF
    SUDO_USER=perceval
    who() { printf '%s\n' 'perceval pts/0        2026-11-12 12:00 (198.51.100.20)' 'lancelot sshd        2026-11-12 12:10'; }
    report_anonymize "$WORK/report.txt"
    cat "$WORK/report.txt"
    ! grep -q 'lancelot\|perceval\|198\.51\.100\.53' "$WORK/report.txt" || return 1
    ! grep -q 'seedbox-<admin>\|user <admin>' "$WORK/report.txt" || return 1
    grep -qF "Creating the user <sftp-user>" "$WORK/report.txt" \
        && grep -qF "seedbox-<sftp-user>.ppk" "$WORK/report.txt" \
        && grep -qF "Quad9 · 9.9.9.9, 149.112.112.112" "$WORK/report.txt" \
        && grep -qF "AdGuard · 94.140.14.14, 94.140.15.15" "$WORK/report.txt" \
        && grep -qF "clients: 1.1.1.1, 86.54.11.201" "$WORK/report.txt" \
        && grep -qF "clients: <ip>" "$WORK/report.txt"
)

# The SFTP account renamed (a restore, new credentials) is written in the log;
# the report hides both names, in English and in French
sftp_rename_in_log_hidden_in_report() (
    report_load
    seedbox_user_suspend() { :; }
    usermod() { :; }
    getent() { return 1; }
    SFTP_KEYS_DIR="$WORK/rename-keys"
    mkdir -p "$SFTP_KEYS_DIR"
    : >"$APP_LOG"
    seedbox_rename_account arthur lancelot >/dev/null || return 1
    grep -q " · SFTP account arthur renamed to lancelot$" "$APP_LOG" || {
        cat "$APP_LOG"
        return 1
    }
    cat "$APP_LOG" >>"$WORK/report.txt"
    echo "=== 2026-11-13 08:00:00 · Compte SFTP gauvain-dupont renommé en arthur" >>"$WORK/report.txt"
    SUDO_USER=perceval
    who() { :; }
    report_anonymize "$WORK/report.txt"
    cat "$WORK/report.txt"
    ! grep -q 'arthur\|lancelot\|gauvain' "$WORK/report.txt" || return 1
    grep -qF "SFTP account <former-sftp-user> renamed to <sftp-user>" "$WORK/report.txt" \
        && grep -qF "Compte SFTP <former-sftp-user> renommé en <former-sftp-user>" "$WORK/report.txt"
)

# --- Restore cut short: the way back puts back what it replaced -------------------

# Settings, SSH keys of SFTP, certificate of seedtunnel and list of torrents:
# kept before the restore replaces them, put back by the script of the way back
restore_undo_puts_everything_back() (
    load
    local base="$WORK/undo" previous
    rm -rf "$base"
    mkdir -p "$base/bin" "$base/state" "$base/keys" "$base/le/live/seedtunnel" "$base/tr/torrents"
    APP_STATE_DIR="$base/state"
    RESTORE_MARKER="$base/state.restore-unfinished"
    SFTP_KEYS_DIR="$base/keys"
    LETSENCRYPT_ROOT="$base/le"
    TRANSMISSION_STATE_DIR="$base/tr"
    # before the restore
    echo "VPN_PORT=1194" >"$APP_STATE_DIR/vpn.conf"
    echo "key of before" >"$SFTP_KEYS_DIR/lancelot"
    echo "cert of before" >"$LETSENCRYPT_ROOT/live/seedtunnel/cert.pem"
    echo "torrent of before" >"$TRANSMISSION_STATE_DIR/torrents/a.torrent"
    # the restore: settings moved, the rest kept, then replaced
    previous="$APP_STATE_DIR.before-restore-20261111-120000"
    echo "$previous" >"$RESTORE_MARKER"
    mv "$APP_STATE_DIR" "$previous"
    restore_keep_outside "$previous" || return 1
    mkdir -p "$APP_STATE_DIR"
    echo "VPN_PORT=51820" >"$APP_STATE_DIR/vpn.conf"
    echo "key of the backup" >"$SFTP_KEYS_DIR/lancelot"
    echo "cert of the backup" >"$LETSENCRYPT_ROOT/live/seedtunnel/cert.pem"
    rm -rf "$TRANSMISSION_STATE_DIR/torrents"
    # the way back (systemctl and seedtunnel: of the test)
    printf '#!/bin/sh\necho "$0 $*" >>%s\n' "$base/calls" >"$base/bin/systemctl"
    cp "$base/bin/systemctl" "$base/bin/seedtunnel"
    chmod 755 "$base/bin/systemctl" "$base/bin/seedtunnel"
    PATH="$base/bin:$PATH" bash "$previous.undo" || return 1
    [[ $(<"$APP_STATE_DIR/vpn.conf") == "VPN_PORT=1194" && $(<"$SFTP_KEYS_DIR/lancelot") == "key of before" ]] || return 1
    [[ $(<"$LETSENCRYPT_ROOT/live/seedtunnel/cert.pem") == "cert of before" && -f $TRANSMISSION_STATE_DIR/torrents/a.torrent ]] || return 1
    [[ ! -e $RESTORE_MARKER && ! -e $previous && ! -e $previous.outside && ! -e $previous.undo ]] || return 1
    grep -q "seedtunnel apply" "$base/calls"
)

# Seen on a real server: the SFTP account renamed since the backup. The
# restore gives it back the name of the backup (said before the question),
# never takes another account of the system, and its way back gives the old
# name back
restore_takes_back_account_name() (
    load
    local root="$WORK/rename-root" base="$WORK/rename" previous
    rm -rf "$root" "$base"
    mkdir -p "$root/etc/seedtunnel" "$base/bin" "$base/state" "$base/keys"
    (
        SEEDBOX_USER=lancelot
        state_write "$root/etc/seedtunnel/seedbox.conf" SEEDBOX_USER
    )
    vpn_installed() { return 1; }
    seedbox_installed() { return 0; }
    # this server: arthur only
    SEEDBOX_USER=arthur
    id() { [[ ${*: -1} == arthur ]]; }
    restore_check_server "$root" || return 1
    [[ $RESTORE_RENAME_FROM == arthur && $RESTORE_RENAME_TO == lancelot ]] || return 1
    # the same account: nothing to rename
    SEEDBOX_USER=lancelot
    id() { [[ ${*: -1} == lancelot ]]; }
    restore_check_server "$root" || return 1
    [[ -z $RESTORE_RENAME_FROM && -z $RESTORE_RENAME_TO ]] || return 1
    # the account of this server is already gone: nothing to rename (the
    # seedbox makes the one of the backup)
    SEEDBOX_USER=arthur
    id() { return 1; }
    restore_check_server "$root" || return 1
    [[ -z $RESTORE_RENAME_FROM && -z $RESTORE_RENAME_TO ]] || return 1
    # lancelot is another account of this server: refused, nothing planned
    SEEDBOX_USER=arthur
    id() { return 0; }
    if (restore_check_server "$root") >"$WORK/rename.out" 2>&1; then return 1; fi
    grep -q "The account lancelot of the backup already exists on this server" "$WORK/rename.out" || return 1
    # said before the question of the restore
    i18n_load fr
    [[ $(t 'The SFTP account %s takes back the name of the backup: %s.' arthur lancelot) == "Le compte SFTP arthur reprend le nom de la sauvegarde : lancelot." ]] || return 1
    i18n_load en
    # the way back: the old name comes back, then « seedtunnel apply »
    APP_STATE_DIR="$base/state"
    RESTORE_MARKER="$base/state.restore-unfinished"
    SFTP_KEYS_DIR="$base/keys"
    LETSENCRYPT_ROOT="$base/le"
    TRANSMISSION_STATE_DIR="$base/tr"
    echo "SEEDBOX_USER=arthur" >"$APP_STATE_DIR/seedbox.conf"
    echo "key of arthur" >"$SFTP_KEYS_DIR/arthur"
    previous="$APP_STATE_DIR.before-restore-20261112-152000"
    echo "$previous" >"$RESTORE_MARKER"
    mv "$APP_STATE_DIR" "$previous"
    RESTORE_RENAME_FROM=arthur
    RESTORE_RENAME_TO=lancelot
    restore_keep_outside "$previous" || return 1
    bash -n "$previous.undo" || return 1
    # renamed, then the restore stops
    mkdir -p "$APP_STATE_DIR"
    mv "$SFTP_KEYS_DIR/arthur" "$SFTP_KEYS_DIR/lancelot"
    printf '#!/bin/sh\necho "$(basename "$0") $*" >>%s\n' "$base/calls" >"$base/bin/systemctl"
    for command in seedtunnel usermod groupmod; do cp "$base/bin/systemctl" "$base/bin/$command"; done
    # lancelot exists, arthur no longer; its group too
    printf '#!/bin/sh\n[ "$2" = lancelot ]\n' >"$base/bin/id"
    printf '#!/bin/sh\n[ "$2" = lancelot ]\n' >"$base/bin/getent"
    chmod 755 "$base/bin/"*
    PATH="$base/bin:$PATH" bash "$previous.undo" || return 1
    cat "$base/calls"
    grep -qx "usermod --login arthur lancelot" "$base/calls" && grep -qx "groupmod --new-name arthur lancelot" "$base/calls" \
        && [[ $(sed -n '$p' "$base/calls") == "seedtunnel apply" ]] \
        && [[ $(<"$SFTP_KEYS_DIR/arthur") == "key of arthur" && ! -e $SFTP_KEYS_DIR/lancelot ]] || return 1
    # without a rename, the way back touches no account
    RESTORE_RENAME_FROM=""
    RESTORE_RENAME_TO=""
    ! restore_undo_script "$previous" | grep -q "usermod\|groupmod"
)

# --- ufw on: the restore says it before the choice of the file --------------------

restore_refused_with_ufw_first() (
    load
    ufw_on
    banner() { :; }
    backup_pick_file() { echo picked >>"$WORK/ufw-restore-calls"; }
    if (backup_menu_restore) >"$WORK/ufw-restore.out" 2>&1; then return 1; fi
    grep -q "sudo ufw disable" "$WORK/ufw-restore.out" && [[ ! -e $WORK/ufw-restore-calls ]] || return 1
    # by command too, before the passphrase
    touch "$WORK/ufw-restore.enc"
    backup_read_passphrase() { echo passphrase >>"$WORK/ufw-restore-calls"; }
    if (restore_main "$WORK/ufw-restore.enc") >"$WORK/ufw-restore.out" 2>&1; then return 1; fi
    grep -q "sudo ufw disable" "$WORK/ufw-restore.out" && [[ ! -e $WORK/ufw-restore-calls ]]
)

# --- what the real tests showed: restore, removal, full disk, magnet links ------

# The settings a restore replaces are kept aside only if there is something to
# go back to (a new server has only its language and its list of packages),
# and how to delete them is said at the end
restore_keeps_aside_only_settings() (
    restore_archive_load aside
    restore_archive_make aside
    restore_record_steps aside
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    local previous
    # a new server: its language and its list of packages only
    echo fr >"$APP_STATE_DIR/language"
    : >"$APP_STATE_DIR/packages"
    restore_main "$WORK/aside.enc" >"$WORK/aside.out" 2>&1 || {
        cat "$WORK/aside.out"
        return 1
    }
    cat "$WORK/aside.out"
    [[ -z $(compgen -G "$APP_STATE_DIR.before-restore-*") ]] && ! grep -q "Once everything works" "$WORK/aside.out" || return 1
    # nothing kept: not said before either
    grep -q "this server has none of its own yet" "$WORK/aside.out" && ! grep -q "a copy of them is kept" "$WORK/aside.out" || return 1
    # no seedbox in the backup: nothing said about WinSCP / FileZilla
    ! grep -q "Close WinSCP / FileZilla first" "$WORK/aside.out" || return 1
    # now a server with settings: kept aside, and how to delete them said
    restore_main "$WORK/aside.enc" >"$WORK/aside.out" 2>&1 || {
        cat "$WORK/aside.out"
        return 1
    }
    cat "$WORK/aside.out"
    grep -q "a copy of them is kept in /etc" "$WORK/aside.out" || return 1
    previous=$(compgen -G "$APP_STATE_DIR.before-restore-*")
    [[ -n $previous && -f $previous/vpn.conf && ! -e $previous.undo && ! -e $previous.outside ]] \
        && grep -q "The settings it replaced are kept in $previous" "$WORK/aside.out" \
        && grep -q "delete them in Backup / restore › My backups, or:" "$WORK/aside.out" \
        && grep -qxF "  seedtunnel restore clean" "$WORK/aside.out" && ! grep -q "rm -rf" "$WORK/aside.out"
)

# A backup with a seedbox: WinSCP / FileZilla to close first, said in the frame
# before the question (its SFTP account comes back meanwhile)
restore_says_close_sftp_programs() (
    restore_archive_load sftp
    printf 'SEEDBOX_USER=lancelot\n' >"$RESTORE_ROOT/etc/seedtunnel/seedbox.conf"
    restore_archive_make sftp
    confirm() { return 1; }
    (restore_main "$WORK/sftp.enc") >"$WORK/sftp.out" 2>&1
    cat "$WORK/sftp.out"
    grep -q "Close WinSCP / FileZilla first" "$WORK/sftp.out"
)

# Clock not synchronized in the first minutes after a start: said as being
# synchronized, not as a problem; later, a warning
doctor_clock_after_start() (
    load
    timedatectl() { echo no; }
    REBOOT_REQUIRED_FILE="$WORK/clock-no-reboot"
    RESTORE_MARKER="$WORK/clock.restore-unfinished"
    APP_STATE_DIR="$WORK/clock/state"
    PROC_STAT="$WORK/clock-stat"
    rm -rf "$WORK/clock"
    mkdir -p "$APP_STATE_DIR"
    local now
    printf -v now '%(%s)T' -1
    printf 'cpu 1 2 3\nbtime %s\n' "$((now - 150))" >"$PROC_STAT"
    DOCTOR_WARNINGS=0
    doctor_system >"$WORK/clock.out" 2>&1
    grep -q "Clock being synchronized (the server started 2 min ago)" "$WORK/clock.out" && ! grep -q "Clock not synchronized" "$WORK/clock.out" || {
        cat "$WORK/clock.out"
        return 1
    }
    printf 'cpu 1 2 3\nbtime %s\n' "$((now - 3600))" >"$PROC_STAT"
    doctor_system >"$WORK/clock.out" 2>&1
    grep -q "Clock not synchronized: certificates and WireGuard depend on it" "$WORK/clock.out" || return 1
    # start unknown: a warning too
    : >"$PROC_STAT"
    doctor_system >"$WORK/clock.out" 2>&1
    grep -q "Clock not synchronized: certificates and WireGuard depend on it" "$WORK/clock.out"
)

# A backup copied into a home folder (the one this server was restored from)
# counts like in « backup list »: in the menu header and in « Latest »
menu_counts_copied_backups() (
    load
    colors_init off
    BACKUP_DIR="$WORK/latest/var"
    BACKUP_COPIED=("$WORK/latest/home/*/*.tar.gz.enc")
    rm -rf "$WORK/latest"
    mkdir -p "$BACKUP_DIR" "$WORK/latest/home/debian"
    seedbox_installed() { return 0; }
    vpn_installed() { return 1; }
    backup_auto_enabled() { return 1; }
    systemctl() { return 1; }
    ui_status_reset
    home_backup
    [[ ${UI_STATUS_STATES[0]} == "none yet" ]] || return 1
    echo "copied" >"$WORK/latest/home/debian/seedtunnel-old-20261113-160123.tar.gz.enc"
    [[ $(backup_latest) == "$WORK/latest/home/debian/seedtunnel-old-20261113-160123.tar.gz.enc" ]] || return 1
    ui_status_reset
    home_backup
    [[ ${UI_STATUS_STATES[0]} == manual ]] || {
        echo "${UI_STATUS_STATES[*]}"
        return 1
    }
    backup_status_fields >"$WORK/latest.out" 2>&1
    cat "$WORK/latest.out"
    ! grep -q "none yet" "$WORK/latest.out" && grep -q "0 in $BACKUP_DIR" "$WORK/latest.out" || return 1
    # a link is never one of them
    rm "$WORK/latest/home/debian/seedtunnel-old-20261113-160123.tar.gz.enc"
    echo "server" >"$WORK/latest/server.enc"
    ln -s "$WORK/latest/server.enc" "$WORK/latest/home/debian/link.tar.gz.enc"
    ! backup_latest
)

# The diagnostics say the settings replaced by a finished restore, still kept
# with the old keys and passphrase, and how to delete them
doctor_reports_restore_leftovers() (
    load
    timedatectl() { echo yes; }
    REBOOT_REQUIRED_FILE="$WORK/leftovers-no-reboot"
    RESTORE_MARKER="$WORK/leftovers.restore-unfinished"
    APP_STATE_DIR="$WORK/leftovers/state"
    rm -rf "$WORK/leftovers" "$RESTORE_MARKER"
    mkdir -p "$APP_STATE_DIR"
    doctor_system >"$WORK/leftovers.out" 2>&1
    ! grep -q "still kept" "$WORK/leftovers.out" || return 1
    mkdir "$APP_STATE_DIR.before-restore-20261111-120000"
    # a folder that only looks like one is left out
    mkdir "$APP_STATE_DIR.before-restore-mine"
    doctor_system >"$WORK/leftovers.out" 2>&1
    cat "$WORK/leftovers.out"
    grep -qF "Settings replaced by a restore still kept in $APP_STATE_DIR.before-restore-20261111-120000" "$WORK/leftovers.out" \
        && grep -qF "seedtunnel restore clean" "$WORK/leftovers.out" && ! grep -q "rm -rf" "$WORK/leftovers.out" || return 1
    mkdir "$APP_STATE_DIR.before-restore-20261111-130000"
    doctor_system >"$WORK/leftovers.out" 2>&1
    grep -q "Settings replaced by 2 restores still kept" "$WORK/leftovers.out" \
        && grep -qF "seedtunnel restore clean" "$WORK/leftovers.out" && ! grep -q "rm -rf" "$WORK/leftovers.out" || return 1
    # a restore cut short needs them: said by its own line only
    echo "$APP_STATE_DIR.before-restore-20261111-130000" >"$RESTORE_MARKER"
    doctor_system >"$WORK/leftovers.out" 2>&1
    grep -q "A restore did not finish" "$WORK/leftovers.out" && ! grep -q "still kept" "$WORK/leftovers.out"
)

# « seedtunnel restore clean »: the settings kept by finished restores go,
# after a red frame (« no » by default: nothing changes), written in the log.
# Only the folders seedtunnel made (exact name, no link); never during a
# restore cut short (they are its way back).
restore_clean_deletes_old_settings() (
    load
    local out
    RESTORE_MARKER="$WORK/clean.restore-unfinished"
    APP_STATE_DIR="$WORK/clean/state"
    rm -rf "$WORK/clean" "$RESTORE_MARKER"
    mkdir -p "$APP_STATE_DIR" "$WORK/clean/elsewhere"
    # nothing kept: said, nothing asked
    confirm() { echo "asked" >>"$WORK/clean-asked"; }
    rm -f "$WORK/clean-asked"
    out=$(restore_clean 2>&1) || return 1
    [[ $out == *"nothing to delete"* && ! -e $WORK/clean-asked ]] || return 1
    mkdir "$APP_STATE_DIR.before-restore-20261113-062400" "$APP_STATE_DIR.before-restore-mine"
    echo VPN_PORT=1194 >"$APP_STATE_DIR.before-restore-20261113-062400/vpn.conf"
    touch "$APP_STATE_DIR.before-restore-20261113-062400.undo"
    ln -s "$WORK/clean/elsewhere" "$APP_STATE_DIR.before-restore-20261113-070000"
    [[ $(restore_leftovers_dates) == "2026-11-13 06:24" ]] || return 1
    # « no » (the default): nothing changes
    confirm() {
        echo "$*" >>"$WORK/clean-asked"
        return 1
    }
    out=$(restore_clean 2>&1) || return 1
    printf '%s\n' "$out"
    [[ -d $APP_STATE_DIR.before-restore-20261113-062400 && $out == *"restore of 2026-11-13 06:24"* ]] \
        && [[ $out == *"old keys of the VPN, passwords, passphrase"* ]] \
        && [[ $(<"$WORK/clean-asked") == "Delete them? n" ]] || return 1
    # « yes »: only the folder made by seedtunnel goes (with what is beside
    # it), never a link nor another name; written in the log
    confirm() { return 0; }
    : >"$APP_LOG"
    out=$(restore_clean 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    [[ ! -e $APP_STATE_DIR.before-restore-20261113-062400 && ! -e $APP_STATE_DIR.before-restore-20261113-062400.undo ]] \
        && [[ -d $APP_STATE_DIR.before-restore-mine && -L $APP_STATE_DIR.before-restore-20261113-070000 ]] \
        && [[ -d $WORK/clean/elsewhere && $out == *"Old settings deleted."* ]] || return 1
    grep -qF "· Deleting $APP_STATE_DIR.before-restore-20261113-062400" "$APP_LOG" || return 1
    # two restores: both said, both deleted
    mkdir "$APP_STATE_DIR.before-restore-20261112-180000" "$APP_STATE_DIR.before-restore-20261113-080000"
    [[ $(restore_leftovers_dates) == "2026-11-12 18:00, 2026-11-13 08:00" ]] || return 1
    out=$(restore_clean 2>&1) || return 1
    [[ $out == *"2 restores (2026-11-12 18:00, 2026-11-13 08:00)"* && -z $(restore_leftovers) ]] || return 1
    # a restore cut short: they are its way back, nothing deleted
    mkdir "$APP_STATE_DIR.before-restore-20261113-090000"
    echo "$APP_STATE_DIR.before-restore-20261113-090000" >"$RESTORE_MARKER"
    [[ -z $(restore_leftovers_dates) ]] || return 1
    if out=$( (restore_clean) 2>&1); then return 1; fi
    [[ -d $APP_STATE_DIR.before-restore-20261113-090000 && $out == *"A restore did not finish"* ]] || return 1
    # the command « seedtunnel restore clean »
    rm -f "$RESTORE_MARKER"
    restore_clean() { echo "clean"; }
    [[ $(restore_cli clean) == clean ]]
)

# My backups: the settings kept by a finished restore said on a line (since
# when), with [3] to delete them; nothing of it without them, nor during a
# restore cut short
backup_menu_mine_old_settings() (
    back_load
    rm -rf "$WORK/mine-old"
    BACKUP_DIR="$WORK/mine-old/backups"
    BACKUP_COPIED=()
    APP_STATE_DIR="$WORK/mine-old/state"
    RESTORE_MARKER="$WORK/mine-old/state.restore-unfinished"
    mkdir -p "$BACKUP_DIR" "$APP_STATE_DIR"
    answers ""
    backup_menu_mine >"$WORK/mine-old.out" 2>&1 || return 1
    ! grep -q "Old settings\|\[3\]" "$WORK/mine-old.out" || return 1
    mkdir "$APP_STATE_DIR.before-restore-20261113-072400"
    answers ""
    backup_menu_mine >"$WORK/mine-old.out" 2>&1 || return 1
    cat "$WORK/mine-old.out"
    grep -q "Old settings  *kept since the restore of 2026-11-13 07:24" "$WORK/mine-old.out" \
        && grep -q "to delete once everything works" "$WORK/mine-old.out" \
        && grep -q "^  \[3\] Delete the old settings$" "$WORK/mine-old.out" || return 1
    # [3], yes: deleted, the line goes
    confirm() { return 0; }
    answers "3" ""
    backup_menu_mine >"$WORK/mine-old.out" 2>&1 || return 1
    [[ ! -e $APP_STATE_DIR.before-restore-20261113-072400 ]] && grep -q "Old settings deleted." "$WORK/mine-old.out" || return 1
    # a restore cut short: neither the line nor [3]
    mkdir "$APP_STATE_DIR.before-restore-20261113-090000"
    echo "$APP_STATE_DIR.before-restore-20261113-090000" >"$RESTORE_MARKER"
    answers "3" ""
    backup_menu_mine >"$WORK/mine-old.out" 2>&1 || return 1
    ! grep -q "Old settings\|\[3\]" "$WORK/mine-old.out" && [[ -d $APP_STATE_DIR.before-restore-20261113-090000 ]]
)

# « seedtunnel restore » without a file: the list of the backups, as in the
# menu, in a terminal only, where its question is asked
restore_command_without_file() (
    load
    local out
    banner() { :; }
    ufw_refuse() { :; }
    restore_main() { echo "restore $1" >>"$WORK/cli-restore-calls"; }
    rm -f "$WORK/cli-restore-calls"
    # without a terminal: the usage, nothing else
    stdin_is_terminal() { return 1; }
    if out=$( (restore_cli "") 2>&1); then return 1; fi
    echo "$out"
    [[ $out == *"Usage: seedtunnel restore FILE"* && ! -e $WORK/cli-restore-calls ]] || return 1
    # in a terminal: the real list, and its question asked (seen on a real
    # server: refused as « outside interactive mode »)
    stdin_is_terminal() { return 0; }
    BACKUP_DIR="$WORK/cli-pick"
    BACKUP_COPIED=()
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    touch "$BACKUP_DIR/seedtunnel-server-20261112-171024.tar.gz.enc"
    INTERACTIVE=0
    restore_cli "" <<<"1" >"$WORK/cli-pick.out" 2>&1 || {
        cat "$WORK/cli-pick.out"
        return 1
    }
    ! grep -q "outside interactive mode" "$WORK/cli-pick.out" || return 1
    [[ $(<"$WORK/cli-restore-calls") == "restore $BACKUP_DIR/seedtunnel-server-20261112-171024.tar.gz.enc" ]] || return 1
    rm -f "$WORK/cli-restore-calls"
    # going back from the list restores nothing
    backup_pick_file() { return 1; }
    restore_cli "" >/dev/null 2>&1 || return 1
    [[ ! -e $WORK/cli-restore-calls ]] || return 1
    backup_pick_file() { printf -v "$1" '%s' "$WORK/picked.enc"; }
    restore_cli "" >/dev/null 2>&1 || return 1
    # with a file: straight to it
    restore_cli "$WORK/given.enc" >/dev/null 2>&1 || return 1
    cat "$WORK/cli-restore-calls"
    [[ $(<"$WORK/cli-restore-calls") == "restore $WORK/picked.enc"$'\n'"restore $WORK/given.enc" ]] \
        && grep -q 'restore) restore_cli ' "$ROOT/seedtunnel.sh"
)

# Removing the last part (VPN or seedbox) stops the weekly backup and deletes
# its passphrase: said before the question
removal_says_weekly_passphrase_deleted() (
    load
    INTERACTIVE=0
    banner() { :; }
    confirm() { return 1; }
    backup_auto_enabled() { return 0; }
    vpn_count_clients() { echo 2; }
    SEEDBOX_USER=lancelot
    SEEDBOX_DATA_DIR=/srv/seedbox
    # the VPN is the last part
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    vpn_uninstall >"$WORK/removal.out" 2>&1 || return 1
    cat "$WORK/removal.out"
    grep -q "its passphrase saved on the server is deleted" "$WORK/removal.out" || return 1
    # the seedbox stays: nothing said about the weekly backup
    seedbox_installed() { return 0; }
    vpn_uninstall >"$WORK/removal.out" 2>&1 || return 1
    ! grep -q "passphrase saved on the server" "$WORK/removal.out" || return 1
    # the seedbox is the last part
    vpn_installed() { return 1; }
    seedbox_uninstall >"$WORK/removal.out" 2>&1 || return 1
    grep -q "its passphrase saved on the server is deleted" "$WORK/removal.out" || return 1
    # its SFTP account goes: WinSCP / FileZilla to close first, said
    grep -q "Close WinSCP / FileZilla first: their automatic reconnections would be counted as failed logins" "$WORK/removal.out" || return 1
    # the weekly backup off: nothing to say
    backup_auto_enabled() { return 1; }
    seedbox_uninstall >"$WORK/removal.out" 2>&1 || return 1
    ! grep -q "passphrase saved on the server" "$WORK/removal.out"
)

# A full system disk: said before anything is written, in words that speak of
# the disk; a log that cannot be written no longer stops the script
full_disk_said_before_anything() (
    load
    local out
    df() {
        printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n'
        printf '/dev/vda1 20000 19950 %s 100%% /\n' "$FREE_MB"
    }
    FREE_MB=42
    if out=$( (disk_space_check) 2>&1); then return 1; fi
    echo "$out"
    [[ $out == *"The system disk is full (42 MB free on /): nothing was changed"* ]] || return 1
    FREE_MB=9000
    (disk_space_check) || return 1
    # df that fails: nothing stopped
    df() { return 1; }
    (disk_space_check) || return 1
    grep -q "^ *disk_space_check$" "$ROOT/seedtunnel.sh"
)

full_log_does_not_stop() (
    local out
    out=$(strict '
        APP_LOG=/dev/full
        log_title "A step"
        run "Doing something" true
        log_print "a line\n"
        log_run "Stopping something" true
        echo reached' 2>&1)
    echo "$out"
    [[ $out == *reached* && $out == *ok* ]]
)

# The progress bars of dpkg (« Reading database ... 5% ») no longer fill the
# log and the reports
apt_without_progress_bars() (
    packages_load
    apt_get_stub
    apt_install wireguard-tools &>/dev/null || return 1
    printf 'wireguard-tools\n' >"$APP_STATE_DIR/packages"
    printf 'wireguard-tools\n' >>"$WORK/installed"
    apt_purge wireguard-tools &>/dev/null || return 1
    cat "$WORK/apt-calls"
    grep -q " install -y " "$WORK/apt-calls" && grep -q " purge -y " "$WORK/apt-calls" || return 1
    ! grep -E " (install|purge) -y " "$WORK/apt-calls" | grep -qv -- "-o Dpkg::Use-Pty=0"
)

# A kernel installed since the server started is said, even without
# /run/reboot-required (a new Debian); not a kernel given by the host
kernel_installed_since_boot_said() (
    load
    local now
    now=$(date +%s)
    BOOT_DIR="$WORK/boot"
    PROC_STAT="$WORK/proc-stat"
    REBOOT_REQUIRED_FILE="$WORK/kernel-reboot-required"
    rm -rf "$BOOT_DIR" "$REBOOT_REQUIRED_FILE"
    mkdir -p "$BOOT_DIR"
    timedatectl() { echo yes; }
    uname() { echo 6.12.43+deb13-amd64; }
    touch "$BOOT_DIR/vmlinuz-6.12.43+deb13-amd64" "$BOOT_DIR/vmlinuz-6.12.57+deb13-amd64"
    # the server started after both were installed: nothing
    printf 'cpu 1 2 3\nbtime %s\n' "$((now + 100))" >"$PROC_STAT"
    ! kernel_installed_since_boot || return 1
    # started before the newer one was installed
    printf 'cpu 1 2 3\nbtime %s\n' "$((now - 100))" >"$PROC_STAT"
    kernel_installed_since_boot || return 1
    doctor_system >"$WORK/kernel.out" 2>&1
    cat "$WORK/kernel.out"
    grep -q "a kernel installed since the server started is not used yet" "$WORK/kernel.out" || return 1
    # with /run/reboot-required: its own line only
    touch "$REBOOT_REQUIRED_FILE"
    doctor_system >"$WORK/kernel.out" 2>&1
    grep -q "update of the kernel or of a library" "$WORK/kernel.out" \
        && ! grep -q "a kernel installed since" "$WORK/kernel.out" || return 1
    # the kernel running is not one of /boot (given by the host, a container)
    uname() { echo 6.1.0-host; }
    ! kernel_installed_since_boot || return 1
    # no start time readable: nothing
    : >"$PROC_STAT"
    uname() { echo 6.12.43+deb13-amd64; }
    ! kernel_installed_since_boot
)

# Torrents added by a magnet link, without their metadata (HASH.magnet of
# Transmission 4): put back through watch/ by Transmission 4, saved to add
# again by hand with Transmission 3; anything else than one link refused
restore_magnet_links() (
    load
    install_without_owner
    local backup="$WORK/mg-restore/x" source hash=0123456789abcdef0123456789abcdef01234567 link
    link="magnet:?xt=urn:btih:$hash&dn=test&tr=udp%3A%2F%2Ftracker.example.org%3A1337"
    rm -rf "$WORK/mg-restore" "$WORK/mg-data" "$WORK/mg-state" "$WORK/mg-magnets.txt"
    TRANSMISSION_STATE_DIR="$WORK/mg-state"
    SEEDBOX_DATA_DIR="$WORK/mg-data"
    RESTORE_MAGNETS_FILE="$WORK/mg-magnets.txt"
    source="$backup$TRANSMISSION_STATE_DIR"
    mkdir -p "$SEEDBOX_DATA_DIR/watch" "$source/torrents"
    transmission_settings_file() { echo "$WORK/mg-settings.json"; }
    printf '{}\n' >"$WORK/mg-settings.json"
    printf 'd4:infod4:name1:aee' >"$source/torrents/7acf8fb590b2060dd9c3146ef770169d593433b0.torrent"
    printf '%s' "$link" >"$source/torrents/$hash.magnet"
    # not one magnet link: a second line, a space, something else
    printf '%s\nrm -rf /\n' "$link" >"$source/torrents/1111111111111111111111111111111111111111.magnet"
    printf 'magnet:?xt=a b' >"$source/torrents/2222222222222222222222222222222222222222.magnet"
    printf 'https://example.org/x.torrent' >"$source/torrents/3333333333333333333333333333333333333333.magnet"
    # Transmission 4: through watch/, as Transmission wrote it
    transmission_reads_magnets() { return 0; }
    restore_transmission_state "$backup" >"$WORK/mg.out" 2>&1 || {
        cat "$WORK/mg.out"
        return 1
    }
    cat "$WORK/mg.out"
    [[ $(<"$SEEDBOX_DATA_DIR/watch/$hash.magnet") == "$link" ]] || return 1
    [[ $(compgen -G "$SEEDBOX_DATA_DIR/watch/*.magnet" | wc -l) == 1 && ! -e $RESTORE_MAGNETS_FILE ]] || return 1
    grep -q "Magnet links put back: 1" "$WORK/mg.out" && [[ $(grep -c "unexpected content" "$WORK/mg.out") == 3 ]] || return 1
    # Transmission 3: saved in a file of root, to add them by hand
    rm -f "$SEEDBOX_DATA_DIR/watch/"*
    transmission_reads_magnets() { return 1; }
    restore_transmission_state "$backup" >"$WORK/mg.out" 2>&1 || return 1
    cat "$WORK/mg.out"
    [[ $(<"$RESTORE_MAGNETS_FILE") == "$link" && $(stat -c %a "$RESTORE_MAGNETS_FILE") == 600 ]] || return 1
    [[ -z $(compgen -G "$SEEDBOX_DATA_DIR/watch/*.magnet") && -f $SEEDBOX_DATA_DIR/watch/7acf8fb590b2060dd9c3146ef770169d593433b0.torrent ]] \
        && grep -q "Magnet links to add again by hand in the web interface: 1" "$WORK/mg.out" \
        && grep -qF "$RESTORE_MAGNETS_FILE" "$WORK/mg.out"
)

# Transmission 4.0 and later take magnet links from watch/, Transmission 3 does not
transmission_magnets_from_version_4() (
    load
    command -v dpkg >/dev/null || return 0
    dpkg-query() { printf '%s' "$FAKE_VERSION"; }
    FAKE_VERSION=3.00-2.1+deb12u1
    ! transmission_reads_magnets || return 1
    for FAKE_VERSION in 4.0.5-1ubuntu0.1 4.1.0~beta2+dfsg-3+deb13u2 4.1.1+dfsg-1ubuntu1.1; do
        transmission_reads_magnets || return 1
    done
    FAKE_VERSION=""
    ! transmission_reads_magnets
)

# --- what the real tests showed: QR code, seedbox installed with an IP address ----

# A client with the longest file that can be expected: a long domain name, four
# DNS servers (two in IPv6), the last number of client
qr_client_load() {
    load
    command -v qrencode >/dev/null || {
        echo "qrencode missing (package qrencode)"
        return 1
    }
    VPN_PUBLIC_ADDRESS=un-nom-de-domaine-assez-long.example.org
    VPN_PORT=51820
    VPN_DNS="1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001"
    mkdir -p "$VPN_CLIENTS_DIR"
    echo 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=' >"$VPN_STATE_DIR/server.pub"
    cat >"$VPN_CLIENTS_DIR/telephone-salon.env" <<'EOF'
CLIENT_NUMBER=252
CLIENT_PUBLIC_KEY=Hrl5Wv0hrZ0n3PB0Uc6nGcqIhAb8eOS2t8Wf8V9tS0E=
CLIENT_PRESHARED_KEY=/UwcSPg38hW/D9Y3tcS1FOV0K1wuURMbS/sesJEP5ak=
CLIENT_PRIVATE_KEY=yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
EOF
    vpn_generate_client_conf telephone-salon >"$VPN_CLIENTS_DIR/telephone-salon.conf"
}

# The comments of the file of a client in the language of seedtunnel; the
# settings themselves the same in every language
client_file_comments_translated() (
    # no QR code here: qrencode not needed
    qrencode() { :; }
    qr_client_load || return 1
    local english french
    english=$(vpn_generate_client_conf telephone-salon) || return 1
    i18n_load fr
    french=$(vpn_generate_client_conf telephone-salon) || return 1
    printf '%s\n' "$french"
    grep -qxF '# seedtunnel — client « telephone-salon » — IP 10.8.0.253 — port ouvert 60252' <<<"$french" \
        && grep -qxF "# ::/0 envoie aussi l'IPv6 dans le tunnel (où il est bloqué) : aucune fuite IPv6" <<<"$french" \
        && grep -qxF '# Garde le tunnel ouvert derrière une box : nécessaire pour le port ouvert' <<<"$french" || return 1
    [[ $(grep -v '^#' <<<"$english") == "$(grep -v '^#' <<<"$french")" ]] && grep -q '^# seedtunnel — client "telephone-salon"' <<<"$english"
)

# Frames: a line wrapped never before « : », « ? », « ! », « ; », « » », nor
# after « « » (French spacing), and the line keeps its width
box_keeps_french_punctuation() (
    load
    colors_init off
    UI_COLUMNS=40
    ui_width
    local out
    out=$(ui_box bad "Titre" "Par l'adresse publique du serveur : elle suffit toujours. Tapez de nouveau « oui » maintenant ?")
    printf '%s\n' "$out"
    ! grep -qE '│ (:|\?|»)' <<<"$out" && ! grep -qE '« │|«$' <<<"$out" || return 1
    local line widths=""
    while IFS= read -r line; do
        ui_len "$line"
        widths+=" $UI_LEN"
    done <<<"$out"
    [[ $(tr ' ' '\n' <<<"$widths" | sed '/^$/d' | sort -u | wc -l) == 1 ]] && ! grep -q $'\x01' <<<"$out"
)

# The widest line of QR code (its squares) in what was shown
qr_widest() {
    local line widest=0
    while IFS= read -r line; do
        [[ $line == *█* ]] || continue
        ui_len "$line"
        ((UI_LEN > widest)) && widest=$UI_LEN
    done
    echo "$widest"
}

# Seen on a real server: the QR code of a client, 89 columns wide, did not fit
# in a window of 80 (its lines wrapped, no phone could read it). Made without
# the comments of the file, it fits, even for the longest file; the file keeps
# them.
vpn_qr_fits_80_columns() (
    qr_client_load || return 1
    local out widest
    out=$(vpn_show_client telephone-salon 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    widest=$(qr_widest <<<"$out")
    echo "widest line of the QR code: $widest columns"
    ((widest > 0 && widest <= 80)) || return 1
    grep -q '^# seedtunnel — client "telephone-salon"' "$VPN_CLIENTS_DIR/telephone-salon.conf"
)

# What goes into the QR code: the same settings, without comments, empty lines
# or spaces around « = » and after « , »
vpn_qr_text_keeps_the_settings() (
    qr_client_load || return 1
    local out expected
    out=$(vpn_qr_text "$VPN_CLIENTS_DIR/telephone-salon.conf")
    expected="[Interface]
PrivateKey=yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address=10.8.0.253/32
DNS=1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001
[Peer]
PublicKey=xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
PresharedKey=/UwcSPg38hW/D9Y3tcS1FOV0K1wuURMbS/sesJEP5ak=
Endpoint=un-nom-de-domaine-assez-long.example.org:51820
AllowedIPs=0.0.0.0/0,::/0
PersistentKeepalive=25"
    [[ $out == "$expected" ]] || {
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$out")
        return 1
    }
)

# A window too small for the QR code: what to do is said instead of a QR code
# cut by the terminal; big enough, or not a terminal: the QR code
vpn_qr_window_too_small() (
    qr_client_load || return 1
    local out
    stdout_is_terminal() { return 0; }
    ui_terminal_size() { echo "24 80"; }
    seedbox_installed() { return 1; }
    out=$(vpn_print_qr "$VPN_CLIENTS_DIR/telephone-salon.conf" telephone-salon 2>&1)
    printf '%s\n' "$out"
    [[ $out == *"Window too small for the QR code"*"this one has 80 and 24"*"seedtunnel vpn show telephone-salon"* ]] || return 1
    # the one-time link is offered too, with or without a seedbox (the site
    # of the links)
    [[ $out != *█* && $out == *"seedtunnel vpn share telephone-salon"* ]] || return 1
    ui_terminal_size() { echo "50 100"; }
    out=$(vpn_print_qr "$VPN_CLIENTS_DIR/telephone-salon.conf" telephone-salon 2>&1)
    [[ $out == *█* && $out != *"Window too small"* ]] || return 1
    # size unknown, or the output is not a terminal: the QR code
    ui_terminal_size() { :; }
    out=$(vpn_print_qr "$VPN_CLIENTS_DIR/telephone-salon.conf" telephone-salon 2>&1)
    [[ $out == *█* ]] || return 1
    stdout_is_terminal() { return 1; }
    ui_terminal_size() { echo "24 40"; }
    out=$(vpn_print_qr "$VPN_CLIENTS_DIR/telephone-salon.conf" telephone-salon 2>&1)
    [[ $out == *█* ]]
)

# Seen on a real server installed with its IP address: two warnings, the second
# one advising « seedtunnel seedbox domain <the same IP> », which changes
# nothing. One warning now, that asks for a domain name. A domain name whose
# Let's Encrypt certificate failed keeps its advice (it tries again).
doctor_ip_one_clear_warning() (
    load
    local out
    certificate_days_left() { echo 3600; }
    SEEDBOX_CERTIFICATE=selfsigned
    SEEDBOX_DOMAIN=203.0.113.10
    DOCTOR_WARNINGS=0
    DOCTOR_ERRORS=0
    out=$(
        doctor_name_certificate 203.0.113.10
        echo "warnings=$DOCTOR_WARNINGS errors=$DOCTOR_ERRORS"
    )
    printf '%s\n' "$out"
    [[ $out == *"warnings=1 errors=0"* && $out == *"seedtunnel seedbox domain NAME"* ]] || return 1
    [[ $out != *"seedbox domain 203.0.113.10"* ]] || return 1
    SEEDBOX_DOMAIN=seed.example.net
    dns_points_here() { return 0; }
    out=$(
        doctor_name_certificate 203.0.113.10
        echo "warnings=$DOCTOR_WARNINGS errors=$DOCTOR_ERRORS"
    )
    printf '%s\n' "$out"
    [[ $out == *"warnings=1 errors=0"* && $out == *"seedtunnel seedbox domain seed.example.net"* ]]
)

# Seen in the log of a real server installed with its IP address: removing the
# seedbox asked certbot to delete a certificate that never existed (« No
# certificate found … Ask for help »). Only when there is one now.
seedbox_removal_without_letsencrypt() (
    load
    LETSENCRYPT_ROOT="$WORK/letsencrypt-removal"
    certbot() { echo "certbot $*" >>"$WORK/certbot-calls"; }
    rm -rf "$LETSENCRYPT_ROOT" "$WORK/certbot-calls"
    seedbox_letsencrypt_delete || return 1
    [[ ! -e $WORK/certbot-calls ]] || return 1
    mkdir -p "$LETSENCRYPT_ROOT/renewal"
    : >"$LETSENCRYPT_ROOT/renewal/seedtunnel.conf"
    seedbox_letsencrypt_delete || return 1
    grep -q "^certbot delete --cert-name seedtunnel" "$WORK/certbot-calls" || return 1
    grep -q "· Deleting the Let's Encrypt certificate$" "$APP_LOG" || return 1
    rm -rf "$LETSENCRYPT_ROOT" "$WORK/certbot-calls"
)

# Seen on a real server installed with its IP address: « Creating a
# self-signed certificate (fallback) », while it was the choice. « (fallback) »
# only for a domain name whose Let's Encrypt certificate failed.
selfsigned_title_with_an_ip() (
    load
    SEEDBOX_SSL_DIR="$WORK/ssl-title"
    rm -rf "$SEEDBOX_SSL_DIR" "$WORK/ssl-titles"
    run() { echo "$1" >>"$WORK/ssl-titles"; }
    SEEDBOX_DOMAIN=203.0.113.10
    seedbox_selfsigned_ensure || return 1
    SEEDBOX_DOMAIN=seed.example.net
    seedbox_selfsigned_ensure || return 1
    cat "$WORK/ssl-titles"
    [[ $(cat "$WORK/ssl-titles") == "Creating a self-signed certificate
Creating a self-signed certificate (fallback)" ]] || return 1
    rm -rf "$SEEDBOX_SSL_DIR" "$WORK/ssl-titles"
)

# --- Screens redone for 1.0.0 ---------------------------------------------------------

# Fields in a frame: the values in one column; at 40 columns, a value too long
# goes on under itself, never past the frame
ui_box_fields_aligned_and_wrapped() (
    load
    local out line
    UI_COLUMNS=80
    ui_width
    ui_field_add Address 203.0.113.10
    ui_field_add "Open port" "60004 (TCP and UDP)"
    # (not in a subshell: the fields are emptied once shown)
    ui_box_fields info Summary >"$WORK/box.out"
    out=$(<"$WORK/box.out")
    printf '%s\n' "$out"
    grep -q "^  ┌─ ● Summary ─" <<<"$out" && grep -q "│ Address    203.0.113.10 *│$" <<<"$out" \
        && grep -q "│ Open port  60004 (TCP and UDP) *│$" <<<"$out" || return 1
    UI_COLUMNS=40
    ui_width
    ui_field_add File /etc/seedtunnel/vpn/clients/a-rather-long-name.conf
    ui_box_fields ok Card >"$WORK/box.out"
    out=$(<"$WORK/box.out")
    printf '%s\n' "$out"
    while IFS= read -r line; do
        ui_len "$line"
        ((UI_LEN <= 39)) || return 1
    done <<<"$out"
    grep -q "│ File  /etc/seedtunnel/" <<<"$out" && grep -q "│       /a-rather-long-name.conf" <<<"$out" \
        && (($(grep -c '│' <<<"$out") == 2))
)

# A long text of lang/ on a screen: each line wrapped to its width, its
# beginning as it is, the rest under the value of « Name : value »; an address
# alone on its line is never cut (copied whole)
ui_text_wraps_but_never_cuts_an_address() (
    load
    local out line
    UI_COLUMNS=40
    ui_width
    out=$(printf '%s\n' "  Android     : Settings → VPN → WireGuard (gear) → « Always-on VPN »" \
        "sftp://lancelot;fingerprint=ssh-ed25519-gAp02kYYmtWjmhPTLe83f2mfoeAcy@seed.example.net:22/" | ui_text)
    printf '%s\n' "$out"
    # (« and » keep their word: no-break spaces)
    out=${out//$'\xc2\xa0'/ }
    [[ $(sed -n 1p <<<"$out") == "  Android     : Settings → VPN →" ]] || return 1
    # the next lines under the value of « Name : value »
    [[ $(sed -n 2p <<<"$out") == "                WireGuard (gear) →" && $(sed -n 3p <<<"$out") == "                « Always-on VPN »" ]] || return 1
    [[ $(tail -n 1 <<<"$out") == "sftp://lancelot;fingerprint=ssh-ed25519-gAp02kYYmtWjmhPTLe83f2mfoeAcy@seed.example.net:22/" ]] || return 1
    # a path in a sentence: on a line of its own, whole
    out=$(printf '%s\n' "             with the file /etc/seedtunnel/vpn/clients/telephone-salon.conf" | ui_text)
    printf '%s\n' "$out"
    [[ $(sed -n 1p <<<"$out") == "             with the file" && $(sed -n 2p <<<"$out") == "               /etc/seedtunnel/vpn/clients/telephone-salon.conf" ]] || return 1
    # a command after two spaces: on one line
    out=$(printf '%s\n' "  To get it onto the computer:  seedtunnel vpn share telephone-salon" | ui_text)
    printf '%s\n' "$out"
    [[ $(sed -n 1p <<<"$out") == "  To get it onto the computer:" && $(sed -n 2p <<<"$out") == "    seedtunnel vpn share telephone-salon" ]]
)

# Add or show a client, in the menus: the card, then the QR code alone (the
# key to go on right under it), then what to do, with [1] for the file and
# [2] for a one-time link (with the seedbox only)
vpn_client_screens() (
    qr_client_load || return 1
    local out
    INTERACTIVE=1
    clear() { echo "--- clear"; }
    stdout_is_terminal() { return 1; }
    seedbox_installed() { return 1; }
    out=$(printf '\n\n1\n\nb\n' | vpn_show_client telephone-salon 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    printf '%s\n' "$out"
    # the card, before the QR code
    [[ $out == *'● Client "telephone-salon"'*"Address in the VPN  10.8.0.253"*"Open port"*"60252 (TCP and UDP)"*"--- clear"*█* ]] || return 1
    # the QR code alone on its screen: nothing between the clearing and it,
    # the key to go on right under its last line
    [[ $(grep -A1 -- "--- clear" <<<"$out" | sed -n 2p) == *█* ]] || return 1
    # (the key line is the prompt of « read »: shown only on a terminal)
    [[ $(grep -A1 '█' <<<"$out" | tail -n 1) == "--- clear" ]] && declare -f vpn_qr_screen | grep -q "ui_pause next tight" || return 1
    # then what to do, in three parts, the keys, the file shown by 1
    [[ $out == *"● Install the tunnel"*"Phone"*"« Scan from QR code »"*"through"*"[2] or [1]"*"● Port for torrents"*"● Kill switch"*"[1] Show the file (to copy and paste)"*"[2] One-time download link for the file"*"[Interface]"* ]] || return 1
    [[ $out != *"[y/N]"* ]] || return 1
    # with the seedbox: the same
    seedbox_installed() { return 0; }
    out=$(printf '\n\nb\n' | vpn_show_client telephone-salon 2>&1)
    [[ $out == *"[2] One-time download link for the file"* ]] || return 1
    # after « Add a client »: no card again (it was just shown)
    out=$(printf '\nb\n' | vpn_show_client telephone-salon created 2>&1)
    [[ $out != *"Address in the VPN"* && $out == *█* ]] || return 1
    # for the commands: unchanged (the QR code, what to do, the file)
    INTERACTIVE=0
    out=$(vpn_show_client telephone-salon 2>&1)
    [[ $out == *█*"Phone    : WireGuard app"*"[Interface]"* && $out != *"[1]"* ]]
)

# The QR code too big for the window, in the menus: said with R to show it
# again (no command to type), and Enter goes on
vpn_qr_screen_too_small() (
    qr_client_load || return 1
    local out
    INTERACTIVE=1
    clear() { :; }
    stdout_is_terminal() { return 0; }
    ui_terminal_size() { echo "24 80"; }
    seedbox_installed() { return 0; }
    out=$(printf 'r\n\n' | vpn_qr_screen telephone-salon 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    printf '%s\n' "$out"
    (($(grep -c "Window too small for the QR code" <<<"$out") == 2)) || return 1
    [[ $out == *"then R to show it again"*"Or Enter, then 2"* && $out != *"seedtunnel vpn show"* && $out != *█* ]] || return 1
    # 37 lines for the QR code of this client (the longest file), and one
    # more for the key: 38
    ui_terminal_size() { echo "37 80"; }
    out=$(printf '\n' | vpn_qr_screen telephone-salon 2>&1)
    [[ $out == *"it needs 73 columns and 38 lines"* ]] || return 1
    ui_terminal_size() { echo "38 80"; }
    out=$(printf '\n' | vpn_qr_screen telephone-salon 2>&1)
    [[ $out == *█* ]]
)

# The DNS to choose from: like the entries of a menu, a ● on the one in use;
# at 40 columns, the note under the name
vpn_dns_choices_mark_the_one_in_use() (
    load
    local out line
    UI_COLUMNS=80
    out=$(vpn_dns_choices 3)
    printf '%s\n' "$out"
    grep -qx "  \[3\] DNS4EU ●      European Union, blocks malicious domains" <<<"$out" \
        && grep -qx "  \[1\] Quad9         blocks malicious domains (Swiss foundation)" <<<"$out" \
        && (($(grep -c '●' <<<"$out") == 1)) || return 1
    UI_COLUMNS=40
    out=$(vpn_dns_choices 1)
    printf '%s\n' "$out"
    while IFS= read -r line; do
        ui_len "$line"
        ((UI_LEN <= 39)) || return 1
    done <<<"$out"
    grep -qx "  \[1\] Quad9 ●" <<<"$out" && grep -qx "      blocks malicious domains (Swiss" <<<"$out"
)

# Change of the address or the port: a summary in a frame, « before → after »
# for what changes
vpn_settings_summary_shows_the_change() (
    back_load
    local out
    VPN_OUT_INTERFACE=eth0
    VPN_DNS="9.9.9.9, 149.112.112.112"
    vpn_port_is_free() { return 0; }
    ssh_session_source() { echo 198.51.100.7; }
    confirm() { return 0; }
    answers 203.0.113.10 51821
    out=$(vpn_ask_settings change 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    printf '%s\n' "$out"
    [[ $out == *"● Summary"*"│ Address  203.0.113.10 "*"│ Port     51820 → 51821/udp"*"│ DNS      Quad9 · 9.9.9.9, 149.112.112.112"*"│ Way out  interface eth0"* ]] || return 1
    [[ $out == *"New port: the VPN restarts"* ]] || return 1
    # the installation: no arrow
    VPN_PORT=51820
    answers 203.0.113.10 51821 1
    out=$(vpn_ask_settings install 2>&1)
    [[ $out == *"│ Port     51821/udp"* && $out != *"→"* ]]
)

# The backups in their menu: aligned fields, the weekly backup on (green),
# off (yellow) or failed (red), the latest one, how many, the last download
backup_status_fields_states() (
    load
    local out
    UI_COLUMNS=80
    ui_width
    BACKUP_DIR="$WORK/status-backups"
    mkdir -p "$BACKUP_DIR"
    touch "$BACKUP_DIR/a.tar.gz.enc" "$BACKUP_DIR/b-auto.tar.gz.enc"
    BACKUP_PASSPHRASE_FILE="$WORK/status-passphrase"
    echo x >"$BACKUP_PASSPHRASE_FILE"
    BACKUP_DOWNLOADED_MARK="$WORK/status-mark"
    rm -f "$BACKUP_DOWNLOADED_MARK"
    backup_auto_enabled() { return 0; }
    systemctl() { return 1; }
    out=$(backup_status_fields)
    printf '%s\n' "$out"
    [[ $out == *"Weekly         ● turned on · the last 4 are kept"*"Latest         "*"(today)"*"On the server  2 in $BACKUP_DIR"*"Downloaded     ● not yet"* ]] || return 1
    systemctl() { [[ $1 == is-failed ]]; }
    [[ $(backup_status_fields) == *"Weekly         ● failed"* ]] || return 1
    backup_auto_enabled() { return 1; }
    touch "$BACKUP_DOWNLOADED_MARK"
    out=$(backup_status_fields)
    [[ $out == *"Weekly         ● turned off"* && $out == *"Downloaded     today"* ]] || return 1
    rm -f "$BACKUP_DIR"/*.enc
    [[ $(backup_status_fields) == *"Latest         ● none yet"*"On the server  0 in"* ]]
)

# Seen on a real server: after a restore from the menu, the menus stayed in
# the language of the start of the session. They now go on in the language
# saved by the backup; SEEDTUNNEL_LANG still wins, and with nothing saved the
# language of the run stays.
language_back_after_restore() (
    load
    unset SEEDTUNNEL_LANG
    rm -f "$APP_LANG_FILE"
    i18n_load en
    language_reload
    [[ $APP_LANG == en ]] || return 1
    clear() { :; }
    backup_status_fields() { :; }
    ui_action() { [[ $1 != backup_menu_restore ]] || echo fr >"$APP_LANG_FILE"; }
    INTERACTIVE=1
    backup_menu <<<$'3\nb' >/dev/null 2>&1 || return 1
    [[ $APP_LANG == fr && $(t 'Back') == Retour ]] || return 1
    # the home screen reloads it too (a restore run from there)
    echo en >"$APP_LANG_FILE"
    declare -f main_menu | grep -q language_reload || return 1
    language_reload
    [[ $APP_LANG == en ]] || return 1
    SEEDTUNNEL_LANG=fr
    echo en >"$APP_LANG_FILE"
    i18n_load fr
    language_reload
    [[ $APP_LANG == fr ]]
)

# The seedbox: the new login in a frame after a change; the SFTP settings in a
# frame, with the profiles for WinSCP and FileZilla and the two ways to get an
# SSH key (no questions)
seedbox_login_and_sftp_screens() (
    load
    local out
    UI_COLUMNS=80
    SEEDBOX_DOMAIN=seed.example.net
    SEEDBOX_USER=lancelot
    ssh_first_port() { echo 2222; }
    SEEDBOX_NEW_PASSWORD=dGgNV5GVohRrW1ClQuk4
    out=$(seedbox_login_card 2>&1)
    printf '%s\n' "$out"
    [[ $out == *"✔ New login saved"*"│ Web interface  https://seed.example.net/"*"│ SFTP           seed.example.net, port 2222"*"│ User           lancelot"*"│ Password       dGgNV5GVohRrW1ClQuk4"*"Write this down"* ]] || return 1
    SEEDBOX_NEW_PASSWORD=""
    out=$(seedbox_login_card 2>&1)
    [[ $out != *Password* && $out != *"Write this down"* ]] || return 1
    INTERACTIVE=1
    clear() { :; }
    host_key_fingerprint() { echo "SHA256:gAp02kYYmtWjmhPTLe83f2mfoeAcy+//GMfI045u0U0 ED25519"; }
    winscp_url() { echo "sftp://lancelot;fingerprint=x@seed.example.net:2222/"; }
    SEEDBOX_SFTP_PASSWORD=no
    out=$(seedbox_sftp_config <<<b 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    printf '%s\n' "$out"
    [[ $out == *"SFTP connection (WinSCP, FileZilla)"*"● Settings of the connection"*"│ Host         seed.example.net"*"│ Port         2222"*"│ User         lancelot (SSH key only)"*"│ Fingerprint  SHA256:"* ]] || return 1
    [[ $out == *"Profiles to import (one-time links):"*"[1] WinSCP profile"*"[2] FileZilla profile"* ]] || return 1
    [[ $out == *"an SSH key is two files"*"[3] I have no key"*"through a one-time link. The simplest."*"[4] I already have a key"*"never leaves your computer. The safest."* ]] || return 1
    # the address to paste stays for the commands: the profile does it here
    [[ $out != *"sftp://"* && $out != *"[y/N]"* ]] || return 1
    # for the commands: the same frame, the address, and the commands to use
    INTERACTIVE=0
    out=$(seedbox_sftp_config 2>&1)
    [[ $out == *"│ Host         seed.example.net"*"sftp://lancelot;fingerprint=x@seed.example.net:2222/"* ]] || return 1
    [[ $out == *"seedtunnel seedbox sftp-config winscp"*"seedtunnel seedbox sftp-config filezilla"*"seedtunnel seedbox sftp-key new"* && $out != *"[1]"* ]] || return 1
    # the profile of FileZilla: the frame, but not the address for WinSCP;
    # the one of WinSCP: both
    sftp_profile_share() { echo "profile of $1"; }
    out=$(seedbox_sftp_config filezilla 2>&1)
    [[ $out == *"│ Host         seed.example.net"*"profile of filezilla"* && $out != *"sftp://"* && $out != *"WinSCP:"* ]] || {
        printf '%s\n' "$out"
        return 1
    }
    out=$(seedbox_sftp_config winscp 2>&1)
    [[ $out == *"sftp://lancelot;fingerprint=x@seed.example.net:2222/"*"profile of winscp"* ]] || return 1
    # a request that is not known: refused
    seedbox_require_installed() { :; }
    out=$(seedbox_cli sftp-config cyberduck 2>&1) && return 1
    [[ $out == *"Usage: seedtunnel seedbox sftp-config [winscp|filezilla]"* ]]
)

# The site to import into WinSCP: an INI file of WinSCP with this site only
# (name escaped as WinSCP does it, Windows line ends), no password, and the
# fingerprint of the server among the keys WinSCP knows (without the « = »)
winscp_profile_content() (
    load
    local out expected
    SEEDBOX_DOMAIN=seed.example.net
    SEEDBOX_USER=lancelot
    SFTP_KEYS_DIR="$WORK/profile-keys"
    rm -rf "$SFTP_KEYS_DIR"
    host_key_fingerprint_url() { echo "ssh-ed25519-gAp02kYYmtWjmhPTLe83f2mfoeAcy-__GMfI045u0U0="; }
    out=$(winscp_generate_site 2222 | od -c | tr -s ' ')
    winscp_generate_site 2222 >"$WORK/winscp.ini"
    expected=$(printf '[Sessions\\Seedbox%%20seed.example.net]\r\nHostName=seed.example.net\r\nPortNumber=2222\r\nUserName=lancelot\r\n\r\n[SshHostKeys]\r\nssh-ed25519@2222:seed.example.net=ssh-ed25519-gAp02kYYmtWjmhPTLe83f2mfoeAcy-__GMfI045u0U0\r\n')
    [[ $(cat "$WORK/winscp.ini") == "$expected" ]] || {
        printf '%s\n' "$out"
        return 1
    }
    [[ $(grep -c $'\r$' "$WORK/winscp.ini") == 7 ]] && ! grep -qi password "$WORK/winscp.ini" || return 1
    # a key made by seedtunnel: the site uses it, from the .ssh folder of the
    # personal folder (« % » and « \ » escaped as in WinSCP.ini)
    mkdir -p "$SFTP_KEYS_DIR"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEWuSJMjcPMEGcGPXYQTMQwKBZWAmPq5xBrlCvTXnDEn my laptop" >"$SFTP_KEYS_DIR/lancelot"
    [[ $(winscp_generate_site 22) != *PublicKeyFile* ]] || return 1
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEWuSJMjcPMEGcGPXYQTMQwKBZWAmPq5xBrlCvTXnDEn seedtunnel-lancelot-20261112-085500" >>"$SFTP_KEYS_DIR/lancelot"
    [[ $(winscp_generate_site 22) == *$'UserName=lancelot\r\nPublicKeyFile=%25USERPROFILE%25%5C.ssh%5Cseedbox-lancelot.ppk\r\n\r\n[SshHostKeys]'* ]] || return 1
    # key of the server not found: the site alone
    host_key_fingerprint_url() { :; }
    [[ $(winscp_generate_site 22) != *SshHostKeys* ]]
)

# The steps of the download pages: how to import the profile into WinSCP or
# FileZilla, and with SSH keys only, how to give the key to the site
sftp_profile_steps() (
    load
    local out
    SEEDBOX_DOMAIN=seed.example.net
    fingerprint="SHA256:x ED25519"
    SEEDBOX_SFTP_PASSWORD=yes
    out=$(text share_steps_winscp)
    [[ $out == *"« Tools » → « Import Sites… »"*"« INI file »"*"The password is asked when connecting."*"WinSCP checks by itself"* ]] || return 1
    out=$(text share_steps_filezilla)
    [[ $out == *"The password is asked when connecting."*"must be: <code>SHA256:x ED25519</code>"* ]] || return 1
    SEEDBOX_SFTP_PASSWORD=no
    out=$(text share_steps_winscp)
    [[ $out == *"One step is left"*"give the site your private key"*"« Private key file »"*"choice 3"* && $out != *"The password is asked"* ]] || return 1
    out=$(text share_steps_filezilla)
    [[ $out == *"One step is left"*"« Key file »"* && $out != *"The password is asked"* ]] || return 1
    # fingerprint not known: not said to be in the file
    fingerprint=""
    [[ $(text share_steps_winscp) != *"in the file"* ]] || return 1
    fingerprint="SHA256:x ED25519"
    # the key made by seedtunnel in the profile: where to keep its file
    SEEDBOX_USER=lancelot
    key_in_profile=1
    out=$(text share_steps_winscp)
    [[ $out == *"seedbox-lancelot.ppk"*'C:\Users\YOUR-NAME\.ssh'* && $out != *"One step is left"* ]] || return 1
    out=$(text share_steps_sftp_key)
    [[ $out == *'C:\Users\YOUR-NAME\.ssh'*"finds this key by itself"* ]] || return 1
    key_in_profile=0
    i18n_load fr
    out=$(text share_steps_winscp)
    [[ $out == *"« Outils » → « Importer des sites… »"*"« Fichier INI »"*"Il reste une étape"*"donnez donc votre clé privée au site"* ]] || return 1
    # the Windows folder given as a value: printf keeps its « \ »
    out=$(t 'Keep the file without renaming it, in a folder you keep. On Windows: %s (the WinSCP profile looks for it there).' "$(windows_ssh_folder)" 2>&1)
    [[ $out == *'Sous Windows : C:\Users\VOTRE-NOM\.ssh (le profil WinSCP'* ]]
)

# The screen of a client in the menus: three parts with their title, values
# aligned and wrapped under themselves (under their label on a narrow
# screen), the port and the address in cyan even on a wrapped line, nothing
# wider than the screen, no « … »
vpn_client_guide_layout() (
    load
    local out line
    C_CYAN=$'\e[36m' C_RESET=$'\e[0m' C_GREY=$'\e[2m' C_BOLD=$'\e[1m' C_BRAND=$'\e[35m'
    VPN_PUBLIC_ADDRESS=203.0.113.10
    for UI_COLUMNS in 80 40; do
        ui_width
        out=$(vpn_client_guide 60004 1)
        printf '%s\n' "$out"
        while IFS= read -r line; do
            ui_len "$line"
            ((UI_LEN <= UI_WIDTH)) && [[ $line != *…* ]] || return 1
        done <<<"$out"
        [[ $out == *"●$C_RESET ${C_BOLD}Install the tunnel"*"●$C_RESET ${C_BOLD}Port for torrents"*"●$C_RESET ${C_BOLD}Kill switch"* ]] || return 1
        [[ $out == *"${C_CYAN}60004$C_RESET (TCP and UDP)"*"${C_CYAN}203.0.113.10:60004$C_RESET → this client"* ]] || return 1
        [[ $(tr -s ' \n' ' ' <<<"$out") == *"through [2] or [1]"* ]] || return 1
    done
    # at 80 columns, the values in one column; at 40, under their labels
    UI_COLUMNS=80
    ui_width
    grep -qF "    ${C_GREY}Open port  ${C_RESET}  ${C_CYAN}60004" <<<"$(vpn_client_guide 60004 1)" || return 1
    UI_COLUMNS=40
    ui_width
    [[ $(vpn_client_guide 60004 0 | grep -A1 "Open port" | sed -n 2p) == "      ${C_CYAN}60004$C_RESET (TCP and UDP)" ]] || return 1
    # without the seedbox: no key [2] to speak of
    out=$(vpn_client_guide 60004 0 | tr -s ' \n' ' ')
    [[ $out == *"through [1]"* && $out != *"[2]"* ]]
)

# Cards and summaries before an action: green with « ● »; « ✔ » stays for
# what is done
ui_box_good_and_ok() (
    load
    local out
    C_GREEN=$'\e[1;32m' C_BRAND=$'\e[1;35m' C_RESET=$'\e[0m' C_BOLD=$'\e[1m'
    UI_COLUMNS=80
    ui_width
    ui_field_add Port 51820
    out=$(ui_box_fields good Summary)
    [[ $(sed -n 1p <<<"$out") == "  $C_GREEN┌─ $C_BOLD● Summary"* ]] || return 1
    ui_field_add Port 51820
    out=$(ui_box_fields ok Done)
    [[ $(sed -n 1p <<<"$out") == "  $C_GREEN┌─ $C_BOLD✔ Done"* ]] || return 1
    # every card or summary shown before an action is « good »
    ! grep -n 'ui_box_fields info\|vpn_client_card "$name" info' "$ROOT"/lib/*.sh
)

# Choices with a note: beside the labels when there is room, under them on a
# narrow screen; never wider than the screen, nothing cut, and in French no
# line starts with « : » or « ? »
ui_choices_layout() (
    load
    local out line
    i18n_load fr
    for UI_COLUMNS in 80 40 30; do
        ui_width
        out=$(sftp_key_choices 3 4)
        printf '%s\n' "$out"
        while IFS= read -r line; do
            ui_len "$line"
            ((UI_LEN <= UI_WIDTH)) || return 1
            [[ $line != *…* && ! $line =~ ^\ *[:?] ]] || return 1
        done <<<"$out"
        [[ $(tr -s ' \n' ' ' <<<"$out") == *"Le plus simple."*"Le plus sûr."* ]] || return 1
        if ((UI_COLUMNS == 80)); then
            [[ $out == *"[3] Je n'ai pas de clé  seedtunnel en crée une"* ]] || return 1
        else
            [[ $(grep -A1 -F "[4] J'ai déjà une clé" <<<"$out" | sed -n 2p) == "      collez sa clé publique"* ]] || return 1
        fi
    done
)

# The keys of the list: on two short lines in the menus, as they are for the
# commands
sftp_key_list_lines() (
    load
    local out info="256 SHA256:Hp3cC5YyhRZmLxvU4Lw0dCq9yb6tJ8Sg2kPpd1ZfQ7c seedtunnel-lancelot-20261112-085500 (ED25519)"
    UI_COLUMNS=80
    ui_width
    INTERACTIVE=1
    out=$(sftp_key_line 1 "$info")
    [[ $out == "   1) seedtunnel-lancelot-20261112-085500"$'\n'"      ED25519 · SHA256:Hp3cC5Yy…1ZfQ7c" ]] || {
        printf '%s\n' "$out"
        return 1
    }
    INTERACTIVE=0
    [[ $(sftp_key_line 1 "$info") == "   1) $info" ]]
)

# « I already have a key »: a private key pasted by mistake is named as such,
# its other lines are not read as answers, then the public key is taken
sftp_private_key_pasted() (
    load
    local out key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEWuSJMjcPMEGcGPXYQTMQwKBZWAmPq5xBrlCvTXnDEn laptop"
    # a public key for ssh-keygen: the line that starts with « ssh-ed25519 »
    ssh-keygen() { [[ $(cat) == "ssh-ed25519 "* ]]; }
    INTERACTIVE=1
    sftp_check() {
        local answer
        sftp_ask_public_key answer && printf 'got: %s\n' "$answer"
    }
    out=$({
        printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----" "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ" "-----END OPENSSH PRIVATE KEY-----"
        sleep 2.5
        printf '%s\n' "$key"
    } | sftp_check 2>&1)
    printf '%s\n' "$out"
    [[ $out == *"This is a private key: it stays on your computer."* && $out == *"got: $key"* ]] || return 1
    [[ $(grep -c "Invalid SSH key" <<<"$out") == 0 ]]
)

# --- Site of the links (VPN without a seedbox) --------------------------------------

# Its nginx site: the links (and Let's Encrypt in HTTP) and nothing else, no
# password, no Transmission; with the variables of the seedbox for this call
# only
links_site_serves_only_links() (
    load
    local site
    VPN_PUBLIC_ADDRESS=203.0.113.7
    LINKS_CERTIFICATE=selfsigned
    SEEDBOX_DOMAIN=seed.example.org
    SEEDBOX_CERTIFICATE=letsencrypt
    site=$(links_run links_generate_site)
    printf '%s\n' "$site"
    [[ $site == *"server_name 203.0.113.7;"* && $site == *"location ^~ /share/"* && $site == *"/.well-known/acme-challenge/"* ]] || return 1
    [[ $site == *"$SEEDBOX_SSL_DIR/selfsigned.crt"* && $site != *Strict-Transport-Security* ]] || return 1
    [[ $site != *"auth_basic \"Restricted\""* && $site != *proxy_pass* && $site != *transmission* && $site != *htpasswd* ]] || return 1
    # any other address of the HTTPS site: 404, with the page « nothing here »
    # (the links keep their own page)
    [[ $site == *$'    location / {\n        return 404;\n    }\n}'* ]] || return 1
    local nothing
    nothing=$(sed -n '/location = \/seedtunnel\/nothing-here.html {/,/^    }/p' <<<"$site")
    grep -qx "    error_page 404 /seedtunnel/nothing-here.html;" <<<"$site" && grep -qF "internal;" <<<"$nothing" \
        && grep -qF "alias $ROOT/web/nothing-here.html;" <<<"$nothing" \
        && grep -qF "Content-Security-Policy \"default-src 'none'" <<<"$nothing" \
        && grep -qF 'X-Robots-Tag "noindex, nofollow"' <<<"$nothing" \
        && grep -qF "error_page 404 /seedtunnel/link-gone.html;" <<<"$site" || return 1
    # page missing: the 404 of nginx
    if (APP_DIR=$WORK/elsewhere links_run links_generate_site | grep -q "nothing-here"); then return 1; fi
    # the page stands alone and names nothing
    if grep -qiE 'https?:|src=|href=|url\(|<script|transmission|seedtunnel|seedbox' "$ROOT/web/nothing-here.html"; then return 1; fi
    grep -q "Rien ici" "$ROOT/web/nothing-here.html" && grep -q "Nothing here" "$ROOT/web/nothing-here.html" || return 1
    # the variables of the seedbox untouched
    [[ $SEEDBOX_DOMAIN == seed.example.org && $SEEDBOX_CERTIFICATE == letsencrypt && -z ${NGINX_SITE_GENERATOR-} ]] || return 1
    # Let's Encrypt: its certificate, and HSTS (in the links too)
    LINKS_CERTIFICATE=letsencrypt
    site=$(links_run links_generate_site)
    [[ $site == *"$LETSENCRYPT_DIR/fullchain.pem"* && $(grep -c Strict-Transport-Security <<<"$site") -ge 2 ]] || return 1
    # a domain name in capitals: in small letters
    VPN_PUBLIC_ADDRESS=VPN.Example.ORG
    site=$(links_run links_generate_site)
    [[ $site == *"server_name vpn.example.org;"* ]] || return 1
    # the certificate chosen by the seedbox functions comes back for the
    # site of the links, never for the seedbox
    VPN_PUBLIC_ADDRESS=vpn.example.org
    LINKS_CERTIFICATE=selfsigned
    seedbox_apply_https() {
        printf '%s %s %s %s\n' "$SEEDBOX_DOMAIN" "$NGINX_SITE_GENERATOR" "$SEEDBOX_LETSENCRYPT" "$SEEDBOX_LETSENCRYPT_SERVER" >"$WORK/links-run"
        SEEDBOX_CERTIFICATE=letsencrypt
    }
    links_run seedbox_apply_https
    [[ $(<"$WORK/links-run") == "vpn.example.org links_generate_site auto production" ]] || return 1
    [[ $LINKS_CERTIFICATE == letsencrypt && $SEEDBOX_CERTIFICATE == letsencrypt && $SEEDBOX_DOMAIN == seed.example.org ]]
)

# The firewall opens 80 and 443 for it (not the port of BitTorrent), says it,
# and says when the rules loaded do not have them. A seedbox takes its place.
links_site_in_the_firewall() (
    load
    local rules
    LINKS_CONF_FILE="$WORK/links-firewall.conf"
    rm -f "$LINKS_CONF_FILE"
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    firewall_ssh_ports() { echo 22; }
    VPN_PORT=51820
    rules=$(firewall_generate_rules)
    [[ $rules != *"80, 443"* && $(firewall_summary) != *links* ]] || return 1
    links_save
    links_site_on || return 1
    rules=$(firewall_generate_rules)
    printf '%s\n' "$rules"
    [[ $rules == *"tcp dport { 80, 443 } accept"* && $rules != *"th dport $TORRENT_PORT"* ]] || return 1
    [[ $(firewall_summary) == "SSH (22/tcp), VPN (51820/udp), site of the links (80, 443/tcp)" ]] || return 1
    firewall_rules_missing "$(sed '/80, 443/d' <<<"$rules")" 2>&1 | grep -q "web 80/tcp, web 443/tcp" || return 1
    [[ -z $(firewall_rules_missing "$rules" 2>&1) ]] || return 1
    # with a seedbox: its site serves the links
    seedbox_installed() { return 0; }
    ! links_site_on
)

# The first link without a seedbox: what the site is, then the question
# (--yes without a terminal). No: what to do instead, nothing installed.
# Already there: no question. Neither VPN nor seedbox: refused.
share_require_offers_links_site() (
    load
    local out
    LINKS_CONF_FILE="$WORK/links-require.conf"
    rm -f "$LINKS_CONF_FILE" "$WORK/links-require-calls"
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    VPN_PUBLIC_ADDRESS=203.0.113.7
    links_install() { echo installed >>"$WORK/links-require-calls"; }
    if out=$(share_require "HINT" 2>&1 </dev/null); then return 1; fi
    printf '%s\n' "$out"
    [[ $out == *"Download links go through an HTTPS site"*"https://203.0.113.7/share/…"*"self-signed (IP address)"*"seedtunnel vpn links off"* ]] || return 1
    [[ $out == *"Install the site of the links? (opens ports 80 and 443) → run again with --yes to confirm."* ]] || return 1
    # no: what to do instead, status 1, nothing installed
    confirm() { return 1; }
    if out=$(share_require "what to do instead" 2>&1); then return 1; fi
    [[ $out == *"  what to do instead"* && ! -e $WORK/links-require-calls ]] || return 1
    # a domain name: Let's Encrypt if it points to this server
    VPN_PUBLIC_ADDRESS=vpn.example.org
    out=$(share_require x 2>&1) || true
    [[ $out == *"Let's Encrypt if vpn.example.org points to this server"* ]] || return 1
    # yes: installed
    confirm() { return 0; }
    share_require x >/dev/null 2>&1 || return 1
    [[ $(<"$WORK/links-require-calls") == installed ]] || return 1
    # there: no question; nginx stopped: said
    links_save
    confirm() {
        echo asked
        return 1
    }
    systemctl() { [[ $1 != is-active ]]; }
    if out=$(share_require x 2>&1); then return 1; fi
    [[ $out == *"nginx is stopped:  seedtunnel vpn links on"* && $out != *asked* ]] || return 1
    systemctl() { return 0; }
    out=$(share_require x 2>&1) || return 1
    [[ $out != *asked* ]] || return 1
    # neither VPN nor seedbox (a firewall only): refused, with the hint
    vpn_installed() { return 1; }
    rm -f "$LINKS_CONF_FILE"
    if out=$(share_require "the hint" 2>&1); then return 1; fi
    [[ $out == *"Neither is installed."*"the hint"* ]]
)

# A link through the site of the links: the address of the VPN, its nginx
# site (not the one of the seedbox), the fingerprint of its certificate
links_share_through_vpn_address() (
    share_load vpnsite
    seedbox_installed() { return 1; }
    VPN_PUBLIC_ADDRESS=203.0.113.7
    LINKS_CERTIFICATE=selfsigned
    SEEDBOX_SSL_DIR="$WORK/ssl-links"
    mkdir -p "$SEEDBOX_SSL_DIR"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=203.0.113.7 \
        -keyout "$SEEDBOX_SSL_DIR/selfsigned.key" -out "$SEEDBOX_SSL_DIR/selfsigned.crt" &>/dev/null || return 1
    seedbox_apply_nginx() { printf '%s %s\n' "$SEEDBOX_DOMAIN" "${NGINX_SITE_GENERATOR-}" >"$WORK/links-nginx"; }
    pgrep() { return 0; }
    share_create "$WORK/to-share" phone.conf Title "" Note &>"$WORK/links-share.out" || {
        cat "$WORK/links-share.out"
        return 1
    }
    cat "$WORK/links-share.out"
    [[ $(<"$WORK/links-nginx") == "203.0.113.7 links_generate_site" ]] || return 1
    grep -qE "https://203\.0\.113\.7/share/[0-9a-f]{32}/" "$WORK/links-share.out" || return 1
    [[ $(tr -d ' \n' <"$WORK/links-share.out") == *"$(openssl x509 -in "$SEEDBOX_SSL_DIR/selfsigned.crt" -noout -fingerprint -sha256 | cut -d= -f2)"* ]] || return 1
    # Let's Encrypt: no fingerprint to check
    LINKS_CERTIFICATE=letsencrypt
    share_create "$WORK/to-share" phone.conf Title "" Note &>"$WORK/links-share.out" || return 1
    ! grep -q "SHA-256" "$WORK/links-share.out"
)

# Removed: its links, its nginx site, its certificates, what it installed, its
# ports. With a seedbox, only its settings (the site is the seedbox's).
links_remove_cleans_up() (
    load
    LINKS_CONF_FILE="$WORK/links-remove.conf"
    NGINX_SITE="$WORK/links-remove-site"
    NGINX_SITE_LINK="$WORK/links-remove-link"
    SEEDBOX_SSL_DIR="$WORK/links-remove-ssl"
    LETSENCRYPT_WEBROOT="$WORK/links-remove-webroot"
    SHARE_DIR="$WORK/links-remove-share"
    links_save
    touch "$NGINX_SITE"
    ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
    mkdir -p "$SEEDBOX_SSL_DIR" "$LETSENCRYPT_WEBROOT" "$SHARE_DIR/0123" "$SHARE_DIR.jobs"
    : >"$WORK/links-remove-calls"
    seedbox_installed() { return 1; }
    systemctl() {
        echo "systemctl $*" >>"$WORK/links-remove-calls"
        [[ $1 != is-active ]]
    }
    apt_purge() { echo "purge $*" >>"$WORK/links-remove-calls"; }
    firewall_refresh() { echo firewall >>"$WORK/links-remove-calls"; }
    seedbox_letsencrypt_delete() { echo "certbot delete" >>"$WORK/links-remove-calls"; }
    links_remove || return 1
    cat "$WORK/links-remove-calls"
    [[ ! -e $LINKS_CONF_FILE && ! -e $NGINX_SITE && ! -L $NGINX_SITE_LINK && ! -e $SEEDBOX_SSL_DIR && ! -e $LETSENCRYPT_WEBROOT && ! -e $SHARE_DIR && ! -e $SHARE_DIR.jobs ]] || return 1
    grep -qx "systemctl stop seedtunnel-share-\*" "$WORK/links-remove-calls" \
        && grep -qx "certbot delete" "$WORK/links-remove-calls" \
        && grep -qx "purge nginx nginx-common certbot inotify-tools" "$WORK/links-remove-calls" \
        && [[ $(tail -n 1 "$WORK/links-remove-calls") == firewall ]] || return 1
    # an nginx that stays (there before seedtunnel): reloaded without the site
    systemctl() {
        echo "systemctl $*" >>"$WORK/links-remove-calls"
        return 0
    }
    links_save
    : >"$WORK/links-remove-calls"
    links_remove
    grep -qx "systemctl reload nginx" "$WORK/links-remove-calls" || return 1
    # with a seedbox: its settings only
    seedbox_installed() { return 0; }
    links_save
    touch "$NGINX_SITE"
    : >"$WORK/links-remove-calls"
    links_remove
    [[ ! -e $LINKS_CONF_FILE && -e $NGINX_SITE && ! -s $WORK/links-remove-calls ]]
)

# seedtunnel vpn links [on|off]
vpn_links_command() (
    load
    local out
    LINKS_CONF_FILE="$WORK/links-cli.conf"
    rm -f "$LINKS_CONF_FILE"
    : >"$WORK/links-cli-calls"
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    VPN_PUBLIC_ADDRESS=203.0.113.7
    links_install() {
        echo install >>"$WORK/links-cli-calls"
        links_save
    }
    links_apply() { echo apply >>"$WORK/links-cli-calls"; }
    links_remove() {
        echo remove >>"$WORK/links-cli-calls"
        rm -f "$LINKS_CONF_FILE"
    }
    systemctl() { return 0; }
    out=$(vpn_cli_links "" 2>&1)
    [[ $out == *"No site for the links yet: it is offered at the first link (or:  seedtunnel vpn links on)."* ]] || return 1
    vpn_cli_links on >/dev/null 2>&1 && vpn_cli_links on >/dev/null 2>&1 || return 1
    [[ $(<"$WORK/links-cli-calls") == $'install\napply' ]] || return 1
    out=$(vpn_cli_links "" 2>&1)
    [[ $out == *"Site of the links: "*"HTTPS site on (self-signed)"* ]] || return 1
    # removal: a question (--yes without a terminal)
    if out=$(vpn_cli_links off 2>&1 </dev/null); then return 1; fi
    [[ $out == *"Remove the site of the links? → run again with --yes to confirm."* ]] || return 1
    OPT_YES=1
    out=$(vpn_cli_links off 2>&1) || return 1
    [[ $out == *"Site of the links removed."* && $(tail -n 1 "$WORK/links-cli-calls") == remove ]] || return 1
    out=$(vpn_cli_links off 2>&1)
    [[ $out == *"No site of the links to remove."* ]] || return 1
    # with a seedbox: nothing to install
    seedbox_installed() { return 0; }
    out=$(vpn_cli_links on 2>&1)
    [[ $out == *"The links go through the HTTPS site of the seedbox"* ]] || return 1
    if out=$(vpn_cli_links whatever 2>&1); then return 1; fi
    [[ $out == *"Usage: seedtunnel vpn links [on|off]"* ]]
)

# Backed up and restored as the other settings: only what seedtunnel writes
restore_checks_links_settings() (
    load
    local dir="$WORK/links-restore/etc/seedtunnel"
    mkdir -p "$dir"
    printf 'LINKS_CERTIFICATE=selfsigned\n' >"$dir/links.conf"
    [[ -z $(backup_unsafe_state_file "$dir") && -z $(restore_bad_setting "$dir") ]] || return 1
    printf 'LINKS_CERTIFICATE=letsencrypt\n' >"$dir/links.conf"
    [[ -z $(restore_bad_setting "$dir") ]] || return 1
    printf 'LINKS_CERTIFICATE=staging\n' >"$dir/links.conf"
    [[ $(restore_bad_setting "$dir") == $'LINKS_CERTIFICATE\tetc/seedtunnel/links.conf' ]] || return 1
    printf 'LINKS_CERTIFICATE=selfsigned\nPATH=/tmp\n' >"$dir/links.conf"
    [[ $(backup_unsafe_state_file "$dir") == "$dir/links.conf" ]]
)

# A restore puts the site of the links of the backup back; the site of this
# server stays when the backup has none (nginx keeps serving it)
restore_and_the_links_site() (
    restore_archive_load linksback
    printf 'LINKS_CERTIFICATE=selfsigned\n' >"$RESTORE_ROOT/etc/seedtunnel/links.conf"
    restore_archive_make linksback
    restore_record_steps linksback
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    ss() { :; }
    restore_main "$WORK/linksback.enc" >"$WORK/linksback.out" 2>&1 || {
        cat "$WORK/linksback.out"
        return 1
    }
    cat "$WORK/linksback.out" "$RESTORE_STEPS"
    [[ $(grep -vx -e asked -e kernel -e base "$RESTORE_STEPS" | paste -sd' ') == "vpn links" ]] || return 1
    # this server has one, the backup none: it stays, said
    restore_archive_load linkskept
    restore_archive_make linkskept
    restore_record_steps linkskept
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    links_save
    restore_main "$WORK/linkskept.enc" >"$WORK/linkskept.out" 2>&1 || {
        cat "$WORK/linkskept.out"
        return 1
    }
    cat "$WORK/linkskept.out" "$RESTORE_STEPS"
    [[ -f $LINKS_CONF_FILE ]] && grep -qx links "$RESTORE_STEPS" \
        && grep -q "The site of the links of this server stays (the backup restored has none)." "$WORK/linkskept.out" || return 1
    # the backup has one, ports 80/443 used by another program here: refused
    # before anything is changed
    restore_archive_load linksports
    printf 'LINKS_CERTIFICATE=selfsigned\n' >"$RESTORE_ROOT/etc/seedtunnel/links.conf"
    restore_archive_make linksports
    restore_record_steps linksports
    vpn_installed() { return 0; }
    seedbox_installed() { return 1; }
    ss() { printf '%s\n' 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("apache2",pid=1,fd=4))'; }
    restore_refused_first linksports "before installing the site of the links"
)

# Wired in: apply, a new address of the VPN, removal of the VPN, a seedbox
# installed afterwards
links_site_wired_in() (
    load
    declare -f apply_main | grep -q links_apply || return 1
    declare -f vpn_change_settings | grep -q links_apply || return 1
    declare -f vpn_uninstall | grep -q links_remove || return 1
    declare -f seedbox_apply | grep -qF 'rm -f "$LINKS_CONF_FILE"' || return 1
    # its own words in the Let's Encrypt help
    seedbox_installed() { return 1; }
    [[ $(text letsencrypt_failed_help) == *"seedtunnel vpn links on"* ]] || return 1
    seedbox_installed() { return 0; }
    SEEDBOX_DOMAIN=seed.example.org
    [[ $(text letsencrypt_failed_help) == *"seedtunnel seedbox domain seed.example.org"* ]]
)

# A menu of 10 entries: [10] takes one more character, the texts stay aligned
ui_menu_two_digit_keys() (
    load
    local out i line nine ten
    UI_COLUMNS=80
    ui_width
    for i in {1..10}; do ui_menu_add "$i" "Entry $i"; done
    out=$(ui_menu_show | sed 's/\x1b\[[0-9;]*m//g')
    printf '%s\n' "$out"
    while IFS= read -r line; do
        if [[ $line == *"[9] Entry 9"* ]]; then nine=${line%%Entry 9*}; fi
        if [[ $line == *"[10] Entry 10"* ]]; then ten=${line%%Entry 10*}; fi
    done <<<"$out"
    [[ -n ${nine-} && ${#nine} -eq ${#ten} ]] || return 1
    # one column
    for i in {1..10}; do ui_menu_add "$i" "A rather long entry of the menu, number $i"; done
    out=$(ui_menu_show | sed 's/\x1b\[[0-9;]*m//g')
    [[ $out == *$'\n   [9] A rather long entry of the menu, number 9\n  [10] A rather long'* ]]
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
check "WinSCP profile: this site only, Windows line ends, no password" winscp_profile_content
check "WinSCP / FileZilla profiles: steps of the page, SSH keys only" sftp_profile_steps
check "choices with a note: beside or under, nothing cut (80, 40, 30)" ui_choices_layout
check "SSH keys of the list: two short lines in the menus" sftp_key_list_lines
check "public key asked: a private key pasted is named, not kept" sftp_private_key_pasted
check "frames: cards and summaries green with « ● », « ✔ » when done" ui_box_good_and_ok
check "firewall rules in the menu: frame, open ports, always allowed, forwarded ports" firewall_rules_screen_laid_out
check "client screen: three parts, values under themselves, colors kept, nothing cut" vpn_client_guide_layout
check "domain menu: same name, certificate kept without a new request" domain_change_same_name_keeps_certificate
check "domain menu: warning and confirmation before replacing the certificate" domain_change_warns_before_replacing_certificate
check "domain menu: B (or Q) goes back when the name points elsewhere" domain_change_back_when_name_points_elsewhere
check "domain menu: new name applied once confirmed" domain_change_applied_once_confirmed
check "domain: the seedbox now in a green frame (certificate, end, renewal, public IP), then the two choices" domain_change_screen
check "firewall: change refused → previous rules back, boot file untouched" firewall_change_refused_restores_previous_rules
check "firewall: first activation refused → no rules left" firewall_first_trial_refused_leaves_nothing
check "firewall: change confirmed → becomes the rules loaded at boot" firewall_change_confirmed_becomes_permanent
check "firewall on trial: what to do in a frame; « yes » without a new SSH login: a red frame with the time left" firewall_trial_frames
check "VPN: a change refused by WireGuard is applied at the next run" vpn_change_failed_then_retried
check "VPN: NAT rules loaded by systemd, wg0.conf runs no command (AppArmor, Ubuntu 26.04)" vpn_nat_loaded_by_systemd
check "VPN: the clients cannot reach each other, nothing from outside the tunnel but replies and their open port" vpn_clients_isolated_and_protected
check "VPN: a client name that differs from another only by case refused (command and menu)" vpn_client_names_ignore_case
check "VPN: the addition to its service written, systemd reloaded, before the start" vpn_apply_writes_dropin_before_start
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
check "update: the lock goes over to the new version, never free in between" update_hands_the_lock_over
check "update: the latest version read without jq (before the VPN or the seedbox are installed)" update_without_jq
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
check "Transmission: no program run at the end of a download (and when added, done seeding: Transmission 4), their names emptied" transmission_scripts_turned_off
check "Transmission: umask compared by its value, the text of Transmission 4 written again for Transmission 3" transmission_umask_by_version
check "Transmission: nothing run from the folders where it or SFTP write, settings private when it starts or stops" transmission_dropin_noexec_and_private
check "Transmission: settings in 600 and its folder closed to the others after each run, by its own account" transmission_settings_made_private
check "diagnostics: settings of Transmission readable by all, or a program set to run → warning" doctor_transmission_settings_checked
check "diagnostics: Transmission running with a umask that lets every account write → warning" doctor_transmission_umask_checked
check "SFTP: documents kept by the deletion of the account given back to it, never through a link nor to a download" sftp_documents_given_back
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
check "SFTP: sftp-key add of a missing file: « File not found », nothing added" sftp_keys_import_missing_file
check "SFTP: removing a key that cannot be written → file kept" sftp_keys_remove_failure_keeps_file
check "SFTP: rename undone, group not back → said, account suspended" rename_group_undo_checked
check "restore: archive with a link (to /etc/shadow) refused" restore_refuses_links
check "restore: links of Let's Encrypt to its certificates accepted" restore_accepts_letsencrypt_links
check "restore: settings that could run a command refused" restore_refuses_code_in_settings
check "restore: a backup of a newer settings format refused first, with what to do" restore_checks_settings_format
check "backup: the format of the settings noted with the system" backup_notes_settings_format
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
check "back: restore, wrong passphrase asked again (3 tries, a pasted text is one), then back" restore_wrong_passphrase_asked_again
check "df failing: free space unreadable, nothing stops (diagnostics, full disk)" df_failure_does_not_stop
check "network settings: one value off (IPv6 too) → said, and loaded again" net_hardening_checked_everywhere
check "diagnostics: NAT made for another network interface → error" doctor_nat_checks_interface
check "diagnostics: clients of the VPN not protected (rules of an older version) → warning" doctor_sees_clients_unprotected
check "firewall: rules that do not refuse by default → said (doctor, status)" firewall_policy_checked
check "diagnostics: weekly backup without timer or passphrase → error" doctor_weekly_backup_needs
check "diagnostics: update cut short (.previous left) → said" doctor_reports_unfinished_update
check "services: enabled at boot and running, nothing done when they are" services_put_right
check "VPN: not enabled at boot → said" vpn_enable_failure_said
check "full disk: Transmission that does not start again → kept, said" diskguard_start_failure_said
check "full disk protection: stopped and started again written to the log of seedtunnel too" diskguard_written_to_log
check "validation: IPv4 without leading zero, DNS, public address of the VPN" validators_stricter
check "update (git): only vX.Y.Z tags whose code says that version" update_git_tag_checked
check "language: asked until 1 or 2, saved file written aside" language_asked_again
check "language: first screen like the menus, in English, Enter = English, Q saves nothing" language_first_screen
check "shortcut: link elsewhere put right, another program left alone" shortcut_put_right
check "commands: unknown, or arguments too many → refused before anything" commands_refused_first
check "one-time link: not enough room in /run → no link" share_refused_without_room
check "one-time link: its page is not counted, its file is" share_page_not_limited
check "links: a download refused by the limit leaves no token in error.log of nginx" share_limit_not_in_error_log
check "VPN: NAT rules refused → the clients are not changed" vpn_sync_checks_nat_first
check "VPN: test interface left behind → removed before the check" vpn_kernel_check_cleans_up
check "VPN: new port with a session through the VPN → asked, no by default" vpn_port_change_through_vpn
check "firewall: the message says which new login counts" firewall_message_says_rule
check "weekly backup: new passphrase → the older backups keep theirs (said)" backup_new_passphrase_warns
check "translations: empty, or a stray %, refused" i18n_check_stricter
check "seedbox: the home page asks for the password first" nginx_home_asks_password_first
check "nginx: version never told (port 80 too), one X-Frame-Options on the web interface" nginx_hides_version_one_frame_header
check "French: « Utilisation » for the help of every command, never « Usage »" french_usage_word
check "commands: a subcommand given more arguments than it takes refused before anything is done" cli_refuses_extra_arguments
check "dates: today, yesterday, N days ago (EN, FR)" backup_dates_in_words
check "restore of an older backup: the weekly backup keeps its passphrase" restore_keeps_weekly_passphrase
check "restore: weekly backup without any passphrase → turned off, said" restore_weekly_without_passphrase_off
check "restore: another SFTP account than this server → renamed after the question; another account of the system → refused first" restore_renames_other_sftp_account
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
check "log: cut every month (logrotate, Ubuntu included), from the installation and apply" log_rotation_rule
check "log: a service stopped writes its own title (never a failure)" log_titles_before_service_stops
check "update: the version replaced is kept (one only)" update_keeps_previous_version
check "update back: the version kept comes back and applies the settings" update_back_puts_previous_back
check "update: the version installed written in the log by the new version, at the end of apply" update_logs_the_version_installed
check "update by git: the version installed written in the log" update_git_logs_the_version_installed
check "update back: older version failing → the newer one comes back" update_back_failure_puts_newer_back
check "update back: nothing kept, not older, « no », git → nothing changed" update_back_refused_when_nothing_to_go_back_to
check "update from 2.0: apply keeps a copy of the version replaced" apply_saves_previous_for_back
check "menu: update screen offers the way back when a version is kept" update_menu_offers_way_back
check "diagnostics: BitTorrent port open, closed (warning) or not tested" doctor_tests_torrent_port
check "SFTP password: warning once there is a key, yellow in the menus" sftp_password_warning

check "diagnostics: traffic of the VPN blocked by Docker or another firewall" doctor_sees_vpn_traffic_blocked
check "firewall: what is wrong around it (Docker, another program, nftables, ufw, SSH port) on the home screen and in frames" firewall_findings_cases
check "diagnostics: IPv4 routing off for the VPN or the way out" doctor_sees_routing_off_for_an_interface
check "lock: « sudo kill » for whoever came in by sudo" lock_message_says_sudo_kill
check "firewall: rules gone (or refusing nothing) → apply loads them again" firewall_rules_put_back_when_gone
check "boot: apply puts nginx and fail2ban back, the diagnostics warn" services_put_back_at_boot
check "restore: the file refused is named as in the archive" restore_names_refused_file_as_in_archive
check "home screen: « clients connectés : 1 sur 1 » in French" home_clients_in_french
check "sizes: « 36 GB » in the sentences, « 36GB » in the tables" sizes_with_a_space
check "web interface: style of seedtunnel on Transmission 4 and later" web_interface_style
check "web interface: plain colors for the bars, gradient for 4.1 only" web_interface_bars_plain_colors
check "seedbox menu: services with full names and colored dots, never cut" services_line_never_cut
check "dates: « today », « yesterday » on the days of the calendar" ages_in_calendar_days
check "sizes: free space rounded down, as in the diagnostic" free_space_rounded_down
check "log: titles in the language of the messages, report still anonymous" log_titles_translated
check "restore: a decryption error under its own title in the log" decrypt_errors_under_their_title
check "files changed by hand: a copy is kept and it is said" changed_by_hand_copy_kept
check "fingerprints of the files written: a file deleted since leaves the list" written_list_drops_deleted_files
check "apply: a state file or the list of fingerprints with the same content keeps its date" same_content_not_rewritten
check "files changed by hand: nothing taken for a change after a restore or a return" fingerprints_forgotten_when_unknown
check "nginx: the site « default » of the administrator stays on" nginx_default_site_kept_if_changed
check "page « access denied »: colors of seedtunnel, without its name, only if the page is there" denied_page_discreet
check "web interface: Transmission stopped, a page instead of « 502 Bad Gateway »" stopped_page_instead_of_502
check "page of a link: colors of seedtunnel, single use, numbered steps, nothing fetched elsewhere" share_page_in_colors
check "link used or expired: a page that says so, token still hidden in the log" share_gone_page
check "folder of the links (/share/): page « nothing here », no password, on both sites" share_folder_nothing_here
check "site of the seedbox, any other address: the password first, then the page « nothing here »" seedbox_other_addresses_nothing_here
check "web interface: style of seedtunnel on Transmission 3 too (Debian 12)" web_interface_style_transmission3
check "systems: Debian 12/13 and Ubuntu 24.04/26.04, the others refused with the list" systems_supported
check "systems: Debian 11 refused with the way up (Debian 12, then 13)" debian11_refused_with_the_way_up
check "header: « Ubuntu 26.04 », as « Debian 13 »" header_names_ubuntu
check "header: full name, IPv4 address read on the server, system; narrow screens too" header_name_address_system
check "packages: one APT does not know stops before anything is installed (« universe » on Ubuntu)" packages_without_candidate_stop
check "packages: needrestart quiet during APT, never restarts services" apt_never_lets_needrestart_restart
check "firewall: the ports of ssh.socket stay open" ssh_socket_ports_kept_open
check "doctor: SSH started by ssh.socket is not an error" doctor_ssh_waiting_on_socket
check "SSH started on demand: its configuration read and checked before anyone connects" sshd_checked_before_any_connection
check "Transmission 4.1: uTP off, and no restart at every apply" transmission41_utp_off_without_restarts
check "Transmission 4.1: uTP off from the start, even with the settings of an older one (restore)" transmission41_utp_off_after_older_settings
check "AppArmor (Ubuntu 26.04): Transmission allowed in the data folder, reloaded only when it changes" transmission_apparmor_rules
check "diagnostics: Transmission kept out of the data folder by AppArmor" doctor_sees_transmission_apparmor
check "ufw on: VPN, seedbox and firewall not installed" ufw_stops_the_installations
check "doctor: ufw on is said" doctor_says_ufw
check "restore: a backup of another system is said, nothing asked (tested on real servers)" restore_from_another_system_said
check "backup: noting the system is not a setting changed meanwhile (one archive only)" backup_system_noted_without_second_archive
check "backup: without the fingerprints of the files nor the copies changed by hand" backup_without_fingerprints
check "home screen: the details under the blocks never cut (80 columns)" home_details_never_cut
check "preview: the labels of the real menus" preview_labels_are_those_of_the_menus
check "release: the archive comes with its attestation" release_attested
check "release: files of a version changed by root only (archive in 755/644, update whatever its archive)" release_archive_not_group_writable
check "answers: the spaces around them are not part of them (restore « File not found »)" answers_without_spaces_around
check "restore: the backups found, numbered (/var/backups, /root, /home), a number or a path" restore_picks_a_backup_by_number
check "my backups: numbered, one downloaded by its number, deleted after a question (the last said), copied ones left alone" backup_list_download_delete
check "VPN clients: connected, less than an hour ago, older, not since the VPN started" vpn_last_connection_states
check "VPN clients: since when the VPN runs, or that it is stopped" vpn_table_says_since_when
check "DNS: going back changes nothing, the same DNS applies nothing" vpn_dns_can_go_back
check "DNS: Quad9, Cloudflare, DNS4EU, AdGuard or other, from the menu and by command" vpn_dns_changed
check "bans: address, jail and end of the ban, the soonest first; unbanned by number" bans_listed_with_their_end
check "seedbox unban: an invalid address refused, one not banned said, none: usage; once unbanned, checked again, and the next mistakes said to ban again" unban_checks_the_address
check "seedbox unban: banned again by recidive right after, unbanned again; still banned: failed" unban_again_after_recidive
check "bans: « no address banned », or fail2ban stopped" bans_none_or_fail2ban_stopped
check "removing the seedbox: certificate, user and links under their own titles in the log; python3-systemd removed on its own" seedbox_removal_log_titles
check "restore: torrents through watch/, whatever the version of Transmission (4.1 → 3 included)" restore_torrents_through_watch
check "restore: Transmission stopped and started once" restore_stops_transmission_once
check "diagnostics: a .torrent of watch/ unreadable by Transmission" doctor_sees_watch_unreadable
check "weekly backup off: said and asked first, --yes without a terminal; already off: said, nothing asked" weekly_backup_off_asked
check "weekly backup off: the deletion of its passphrase said at the end, only if there was one" weekly_backup_off_says_passphrase_deleted
check "the request for the password names nothing (« Restricted »)" password_request_names_nothing
check "restore: a step that fails stops it, says how to go back, marker kept" restore_stops_when_a_step_fails
check "no action that changes the server called in an if, || or && (set -e kept)" actions_never_called_in_a_condition
check "restore with ufw on: refused before the choice of the file, and by command" restore_refused_with_ufw_first
check "restore: a name seedtunnel never writes (PATH…), another settings file → refused" restore_refuses_other_names
check "restore: values refused at an installation (account, folder, port, DNS, key of the server) → refused" restore_refuses_unexpected_values
check "restore: a file that could be run → refused; the files of the archive go to root" restore_refuses_programs
check "restore: a VPN client named as no client can be, a control character in a name → refused" restore_refuses_bad_names
check "restore: renewal of the certificate with another command or path → refused, as certbot writes it → accepted" restore_refuses_letsencrypt_commands
check "restore: only the certificate of seedtunnel and the account of Let's Encrypt go back" restore_letsencrypt_only_seedtunnel
check "VPN: wg0.conf takes the first line of the key of the server only" vpn_server_key_one_line
check "VPN: a file of clients/ named as no client can be → no client, nothing of it in wg0.conf nor the NAT rules" vpn_ignores_bad_client_names
check "Transmission: its settings written by its own account, a link beside them never followed by root" transmission_settings_never_through_a_link
check "Transmission: its settings in /etc or in its folder, never where a link of its account leads" transmission_settings_link_to_etc_only
check "links: the token in no argument of the watcher, its job in files of root only" share_token_not_in_arguments
check "links: the stop script deletes the link and the job of the watcher" share_stop_script_cleans_up
check "DNS: one line of addresses (no second line, no space inside an address), saved as « a, b »" dns_one_line_of_addresses
check "backup: refused when it is made if it could not be restored" backup_refused_if_it_could_not_be_restored
check "backup: a file changed while it is read (progress of Transmission) is no failure" backup_file_changed_meanwhile_is_no_failure
check "firewall: rules loaded older than their file are loaded again (restore on the same ports)" firewall_refresh_reloads_stale_rules
check "restore: the last download of a backup and the start of the weekly backup are those of this server" restore_leaves_the_marks_of_the_other_server
check "report: domains and SFTP accounts used before, administrators (also needrestart of Ubuntu 26.04), backups of another server replaced" report_replaces_former_names
check "report: the SFTP account logged in is not an administrator, the DNS of the menu kept" report_sftp_account_and_dns
check "report: the SFTP account renamed is in the log, both names hidden" sftp_rename_in_log_hidden_in_report
check "restore cut short: the way back puts back settings, SSH keys, certificate and torrents" restore_undo_puts_everything_back
check "restore: the SFTP account renamed since the backup takes back its name, never another account, back on the way back" restore_takes_back_account_name
check "restore: a backup with a seedbox says to close WinSCP / FileZilla first" restore_says_close_sftp_programs
check "restore: a path that goes up refused before anything is extracted" restore_refuses_going_up
check "restore: the settings replaced kept aside (and said before) only if there is something to go back to, how to delete them said" restore_keeps_aside_only_settings
check "diagnostics: settings replaced by a finished restore said, with the command to delete them" doctor_reports_restore_leftovers
check "menu: a backup copied into a home folder counts as in « backup list » (header, Latest)" menu_counts_copied_backups
check "diagnostics: clock not synchronized yet just after a start: said as such, not as a problem" doctor_clock_after_start
check "restore clean: the settings kept by restores deleted after a red frame, only those, never during a restore cut short" restore_clean_deletes_old_settings
check "my backups: the settings kept by a restore said, [3] deletes them; nothing during a restore cut short" backup_menu_mine_old_settings
check "restore without a file: the list of the backups in a terminal, the usage without" restore_command_without_file
check "removal of the last part: the end of the weekly backup and of its passphrase said before" removal_says_weekly_passphrase_deleted
check "full system disk: said before anything is written" full_disk_said_before_anything
check "a log that cannot be written (full disk) no longer stops the script" full_log_does_not_stop
check "APT: no progress bars of dpkg in the log" apt_without_progress_bars
check "diagnostics: a kernel installed since the start said, even without /run/reboot-required" kernel_installed_since_boot_said
check "restore: magnet links put back through watch/ (Transmission 4), saved to add by hand (Transmission 3)" restore_magnet_links
check "Transmission 4 and later take magnet links from watch/, Transmission 3 does not" transmission_magnets_from_version_4
check "VPN: the QR code of a client fits in 80 columns, its file keeps its comments" vpn_qr_fits_80_columns
check "VPN: the comments of the file of a client in the language of seedtunnel, its settings the same" client_file_comments_translated
check "frames: French punctuation never alone at the start of a line" box_keeps_french_punctuation
check "VPN: the QR code holds the same settings, without comments nor spaces" vpn_qr_text_keeps_the_settings
check "VPN: window too small for the QR code: what to do is said instead" vpn_qr_window_too_small
check "doctor: installed with an IP, one warning that asks for a domain name" doctor_ip_one_clear_warning
check "seedbox removal: certbot only asked when there is a certificate" seedbox_removal_without_letsencrypt
check "self-signed certificate: « (fallback) » only for a domain name" selfsigned_title_with_an_ip
check "screens: fields in a frame, aligned, long values under themselves" ui_box_fields_aligned_and_wrapped
check "screens: long texts wrapped to the width, an address never cut" ui_text_wraps_but_never_cuts_an_address
check "VPN client in the menus: card, QR code alone, then what to do with F (file) and L (link)" vpn_client_screens
check "VPN client in the menus: QR code too big for the window, R shows it again" vpn_qr_screen_too_small
check "DNS of the clients: the choices like a menu, a ● on the one in use" vpn_dns_choices_mark_the_one_in_use
check "VPN address or port: summary in a frame, « before → after »" vpn_settings_summary_shows_the_change
check "backups menu: weekly on/off/failed, latest, on the server, downloaded" backup_status_fields_states
check "restore from the menu: the menus go on in the language of the backup" language_back_after_restore
check "seedbox: new login in a frame, SFTP settings with profiles and key choices" seedbox_login_and_sftp_screens
check "site of the links: its nginx site serves the links and nothing else, the seedbox untouched" links_site_serves_only_links
check "site of the links: 80 and 443 in the firewall, said, missing ones pointed out; a seedbox takes its place" links_site_in_the_firewall
check "site of the links: offered at the first link without a seedbox (--yes without a terminal), no → what to do instead" share_require_offers_links_site
check "site of the links: a link with the address of the VPN and the fingerprint of its certificate" links_share_through_vpn_address
check "site of the links: removed with its links, certificates, packages and ports; with a seedbox, its settings only" links_remove_cleans_up
check "seedtunnel vpn links [on|off]: state, installed then put back in place, removed after a question" vpn_links_command
check "restore: the settings of the site of the links checked like the others" restore_checks_links_settings
check "restore: the site of the links of the backup put back, the one of this server kept, ports used refused first" restore_and_the_links_site
check "site of the links: applied again by apply and a new address, removed with the VPN, replaced by a seedbox" links_site_wired_in
check "menus: with a key [10], the texts stay aligned (one or two columns)" ui_menu_two_digit_keys
check "backup from the menu: its download offered right away; by command, no question" backup_from_menu_offers_link
printf '\n\033[1m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
((FAIL == 0))
