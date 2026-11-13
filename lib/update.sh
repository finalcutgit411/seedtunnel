#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — update, and applying the configuration again
#
#  Update: downloads the latest version published on GitHub, checks its
#  SHA-256 checksum, then replaces the folder of the script (or « git
#  checkout » of the latest tag if the script was installed with git). The
#  new version then applies its own fixes (« seedtunnel apply »); if that
#  fails, the previous version comes back.
#
#  The version replaced is kept in APP_DIR.old (one only):
#  « seedtunnel update back » puts it back.
# =============================================================================

# version_greater A B → true if A is strictly newer than B
version_greater() {
    [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

update_verify_checksum() {
    (cd "$1" && grep " seedtunnel-$2.tar.gz\$" SHA256SUMS | sha256sum -c -)
}

update_check_syntax() {
    local file
    for file in "$1"/seedtunnel.sh "$1"/lib/*.sh "$1"/lang/*.sh; do
        bash -n "$file" || return 1
    done
}

# The tag of the latest version, from the answer of the GitHub API (standard
# input, indented or not). Without jq: it comes with the VPN or the seedbox,
# and seedtunnel must also update before them.
update_tag_from_json() {
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/'
}

update_from_release() {
    local tag version tmp base
    tag=$(curl -fsSL --max-time 15 "https://api.github.com/repos/$APP_REPO/releases/latest" 2>/dev/null \
        | update_tag_from_json || true)
    [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Cannot find the latest version published on github.com/%s.' "$APP_REPO"
    version=${tag#v}
    if ! version_greater "$version" "$APP_VERSION"; then
        ok 'seedtunnel is up to date (version %s).' "$APP_VERSION"
        return 0
    fi
    say 'Installed version: %s → available: %s' "$APP_VERSION" "$version"
    say '  What is new: %s' "https://github.com/$APP_REPO/releases/tag/$tag"
    echo
    if ! confirm 'Update?' y; then return 0; fi
    # prepared next to the installed version (same disk: switching is a mere
    # renaming), in a folder deleted whatever happens
    tmp=$(mktemp -d "${APP_DIR%/*}/.seedtunnel-update.XXXXXX")
    UPDATE_TMP_DIR=$tmp
    trap 'rm -rf "$UPDATE_TMP_DIR"' EXIT
    base="https://github.com/$APP_REPO/releases/download/$tag"
    run "$(t 'Downloading seedtunnel %s' "$version")" curl -fsSL -o "$tmp/seedtunnel-$version.tar.gz" "$base/seedtunnel-$version.tar.gz"
    run 'Downloading the checksums' curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
    run 'Checking the SHA-256 checksum' update_verify_checksum "$tmp" "$version"
    run 'Extracting' tar -xzf "$tmp/seedtunnel-$version.tar.gz" -C "$tmp"
    run 'Checking the syntax' update_check_syntax "$tmp/seedtunnel-$version"
    update_switch "$tmp/seedtunnel-$version" "$version"
}

# Puts the new version (folder $1) in place of the installed one, which is kept
# until the new one has applied the configuration; if that fails, the installed
# version comes back. Renaming: the running script keeps its files open.
# « mv -T »: never moves a folder into another one by mistake.
update_switch() {
    local new=$1 version=$2 previous="$APP_DIR.previous"
    # left by an update that did not finish: it may be the only working copy
    [[ ! -e $previous ]] \
        || die '%s exists: an earlier update did not finish. If seedtunnel works, delete it (rm -rf %s), then update again.' "$previous" "$previous"
    mv -T "$APP_DIR" "$previous" 2>>"$APP_LOG" \
        || die 'The new version could not be put in place: version %s kept (details in %s).' "$APP_VERSION" "$APP_LOG"
    if ! mv -T "$new" "$APP_DIR" 2>>"$APP_LOG"; then
        mv -T "$previous" "$APP_DIR" 2>>"$APP_LOG" \
            || die 'The new version could not be put in place, nor the previous one put back (details in %s). By hand:  mv %s %s' "$APP_LOG" "$previous" "$APP_DIR"
        die 'The new version could not be put in place: version %s kept (details in %s).' "$APP_VERSION" "$APP_LOG"
    fi
    if update_apply_new; then
        update_keep_old "$previous"
        ok 'seedtunnel updated to version %s (see %s).' "$version" "$APP_DIR/CHANGELOG.md"
        exit 0
    fi
    rm -rf "$APP_DIR.failed"
    if ! { mv -T "$APP_DIR" "$APP_DIR.failed" && mv -T "$previous" "$APP_DIR"; } 2>>"$APP_LOG"; then
        die 'Version %s could not apply the configuration, and version %s could not be put back (details in %s). By hand:  mv %s %s.failed ; mv %s %s ; seedtunnel apply' "$version" "$APP_VERSION" "$APP_LOG" "$APP_DIR" "$APP_DIR" "$previous" "$APP_DIR"
    fi
    update_back_to_previous "$version"
}

# The new version applies the configuration, so that its fixes take effect. It
# runs as a process of its own: the lock is handed over to it.
update_apply_new() {
    echo
    exec 9>&-
    "$APP_DIR/seedtunnel.sh" apply
}

# After a failed update (or a failed way back: « back »): the installed
# version applies its configuration again
update_back_to_previous() {
    warn 'Version %s could not apply the configuration: back to version %s.' "$1" "$APP_VERSION"
    if ! "$APP_DIR/seedtunnel.sh" apply >>"$APP_LOG" 2>&1; then
        die 'Update cancelled: the files of version %s are back, but putting the configuration back into service failed too (details in %s). Run « seedtunnel doctor », then « seedtunnel apply ».' "$APP_VERSION" "$APP_LOG"
    fi
    if [[ ${2-} == back ]]; then die 'Going back cancelled, version %s kept (details in %s).' "$APP_VERSION" "$APP_LOG"; fi
    die 'Update cancelled, version %s kept (details in %s).' "$APP_VERSION" "$APP_LOG"
}

# --- Back to the previous version (« seedtunnel update back ») --------------------

# APP_VERSION written in the code of a folder of seedtunnel (empty if none)
update_dir_version() {
    { awk -F'"' '/^APP_VERSION="/ { print $2; exit }' "$1/lib/common.sh" 2>/dev/null || true; }
}

# The version just replaced goes to APP_DIR.old (the one there before goes)
update_keep_old() {
    rm -rf "$APP_DIR.old"
    mv -T "$1" "$APP_DIR.old" 2>>"$APP_LOG" || rm -rf "$1"
}

# During an update made by a version that deletes the version it replaces
# once « apply » worked: a copy of it is kept, so that the
# way back works from the first update on. Run by « apply ».
update_save_previous() {
    local version
    [[ -f $APP_DIR.previous/seedtunnel.sh && ! -d $APP_DIR/.git ]] || return 0
    version=$(update_dir_version "$APP_DIR.previous")
    [[ -n $version ]] || return 0
    version_greater "$APP_VERSION" "$version" || return 0
    rm -rf "$APP_DIR.old.tmp"
    if cp -a "$APP_DIR.previous" "$APP_DIR.old.tmp" 2>>"$APP_LOG"; then
        rm -rf "$APP_DIR.old"
        mv -T "$APP_DIR.old.tmp" "$APP_DIR.old" 2>>"$APP_LOG" || rm -rf "$APP_DIR.old.tmp"
    else
        rm -rf "$APP_DIR.old.tmp"
    fi
}

# An update that worked, written in the log by the new version at the end of
# its « apply » (the version it replaces, older, waits in APP_DIR.previous):
# the version replaced runs the update but may not write it. Run by « apply ».
update_log_installed() {
    local version
    [[ -f $APP_DIR.previous/seedtunnel.sh ]] || return 0
    version=$(update_dir_version "$APP_DIR.previous")
    if [[ -n $version ]] && version_greater "$APP_VERSION" "$version"; then
        log_title 'Update: %s → %s installed' "$version" "$APP_VERSION"
    fi
}

# Version kept to go back to: empty if there is none, or if it is not older
update_old_version() {
    local version
    [[ -f $APP_DIR.old/seedtunnel.sh ]] || return 0
    version=$(update_dir_version "$APP_DIR.old")
    if [[ -n $version ]] && version_greater "$APP_VERSION" "$version"; then printf '%s' "$version"; fi
}

# Puts the version kept back in place of the installed one, as an update does:
# it applies the configuration again; if that fails, the installed version
# comes back. The newer version is deleted (« seedtunnel update » downloads it
# again).
update_back() {
    local version newer=$APP_VERSION previous="$APP_DIR.previous"
    banner
    section 'Back to the previous version'
    [[ ! -d $APP_DIR/.git ]] || die 'Installed with git: go back with  git -C %s checkout vX.Y.Z  then  seedtunnel apply' "$APP_DIR"
    version=$(update_old_version)
    [[ -n $version ]] || die 'No previous version kept: it is kept from the next update on.'
    danger "$(t 'Back to version %s' "$version")" \
        "$(t 'Version %s replaces version %s and applies the same settings again; if that fails, version %s comes back.' "$version" "$newer" "$newer")"
    if ! confirm "$(t 'Go back to version %s?' "$version")" n; then return 0; fi
    echo
    run 'Checking the syntax' update_check_syntax "$APP_DIR.old"
    [[ ! -e $previous ]] \
        || die '%s exists: an earlier update did not finish. If seedtunnel works, delete it (rm -rf %s), then update again.' "$previous" "$previous"
    mv -T "$APP_DIR" "$previous" 2>>"$APP_LOG" \
        || die 'Version %s could not be put in place: version %s kept (details in %s).' "$version" "$newer" "$APP_LOG"
    if ! mv -T "$APP_DIR.old" "$APP_DIR" 2>>"$APP_LOG"; then
        mv -T "$previous" "$APP_DIR" 2>>"$APP_LOG" \
            || die 'Version %s could not be put in place, nor version %s put back (details in %s). By hand:  mv %s %s' "$version" "$newer" "$APP_LOG" "$previous" "$APP_DIR"
        die 'Version %s could not be put in place: version %s kept (details in %s).' "$version" "$newer" "$APP_LOG"
    fi
    # an older version rewrites files without keeping their fingerprints
    written_forget
    if update_apply_new; then
        rm -rf "$previous"
        log_title 'Back to version %s (version %s removed)' "$version" "$newer"
        ok 'Back to version %s (version %s comes back with  seedtunnel update).' "$version" "$newer"
        exit 0
    fi
    # the older version failed: the newer one comes back, and stays kept
    if ! { mv -T "$APP_DIR" "$APP_DIR.old" && mv -T "$previous" "$APP_DIR"; } 2>>"$APP_LOG"; then
        die 'Version %s could not apply the configuration, and version %s could not be put back (details in %s). By hand:  mv %s %s.old ; mv %s %s ; seedtunnel apply' "$version" "$newer" "$APP_LOG" "$APP_DIR" "$APP_DIR" "$previous" "$APP_DIR"
    fi
    update_back_to_previous "$version" back
}

# seedtunnel update [back]
update_cli() {
    case ${1-} in
        "") update_main ;;
        back) update_back ;;
        *) die 'Usage: seedtunnel update [back]' ;;
    esac
}

# From the menu: with a version kept, a choice between the update and the way
# back; otherwise the update straight away (as in 2.0). Not in a subshell: the
# lock goes to the version put in place.
update_menu() {
    local choice old
    while true; do
        old=$(update_old_version)
        if [[ -z $old || -d $APP_DIR/.git ]]; then
            update_main
            return 0
        fi
        UI_PLACE=("$(t 'Update seedtunnel')")
        ui_top "${UI_PLACE[@]}"
        ui_field_add "$(t 'Installed version')" "$APP_VERSION"
        ui_field_add "$(t 'Previous version kept')" "$old"
        ui_fields_show
        echo
        ui_menu_add 1 "$(t 'Look for an update and install it')"
        ui_menu_add 2 "$(t 'Back to version %s' "$old")"
        ui_menu_show
        echo
        ui_menu_ask choice back
        case ${choice,,} in
            1) update_main ;;
            2)
                update_back
                pause
                ;;
            "" | b) return 0 ;;
            q) ui_quit ;;
        esac
    done
}

# Version written in the code of a git tag (APP_VERSION of lib/common.sh);
# empty if there is none (never a failure, for « set -e »)
update_tag_version() {
    { git -C "$APP_DIR" show "$1:lib/common.sh" 2>/dev/null || true; } | awk -F'"' '/^APP_VERSION="/ { print $2; exit }'
}

update_from_git() {
    local tag="" candidate previous version
    [[ -z $(git -C "$APP_DIR" status --porcelain 2>/dev/null) ]] \
        || die 'The folder %s has local changes: update cancelled.' "$APP_DIR"
    run 'Fetching the published versions' git -C "$APP_DIR" fetch --tags --quiet
    # Newest published version: a vX.Y.Z tag only, holding seedtunnel.sh, whose
    # code says the same version
    # (otherwise the update would go on and on, or go backwards)
    while IFS= read -r candidate; do
        [[ $candidate =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        git -C "$APP_DIR" cat-file -e "$candidate:seedtunnel.sh" 2>/dev/null || continue
        version=$(update_tag_version "$candidate")
        if [[ $version == "${candidate#v}" ]]; then
            tag=$candidate
            break
        fi
        warn 'Tag %s left out: its code says version %s.' "$candidate" "${version:-?}"
    done < <(git -C "$APP_DIR" tag -l 'v*' --sort=-v:refname)
    [[ -n $tag ]] || die 'No published version (vX.Y.Z tag) in the repository.'
    if ! version_greater "${tag#v}" "$APP_VERSION"; then
        ok 'seedtunnel is up to date (version %s).' "$APP_VERSION"
        return 0
    fi
    say 'Installed version: %s → available: %s' "$APP_VERSION" "${tag#v}"
    if ! confirm 'Update?' y; then return 0; fi
    previous=$(git -C "$APP_DIR" rev-parse HEAD)
    run "$(t 'Switching to version %s' "${tag#v}")" git -C "$APP_DIR" -c advice.detachedHead=false checkout --quiet "$tag"
    if update_apply_new; then
        log_title 'Update: %s → %s installed' "$APP_VERSION" "${tag#v}"
        ok 'seedtunnel updated to version %s (see %s).' "${tag#v}" "$APP_DIR/CHANGELOG.md"
        exit 0
    fi
    # back to the previous commit, checked: otherwise « apply » would run the
    # version that just failed
    if ! git -C "$APP_DIR" -c advice.detachedHead=false checkout --quiet "$previous" >>"$APP_LOG" 2>&1 \
        || [[ $(git -C "$APP_DIR" rev-parse HEAD 2>>"$APP_LOG") != "$previous" ]]; then
        die 'Version %s could not apply the configuration, and git could not go back to version %s (details in %s). By hand:  git -C %s checkout %s ; seedtunnel apply' "${tag#v}" "$APP_VERSION" "$APP_LOG" "$APP_DIR" "$previous"
    fi
    update_back_to_previous "${tag#v}"
}

update_main() {
    banner
    section 'Update seedtunnel'
    if [[ -d $APP_DIR/.git ]]; then update_from_git; else update_from_release; fi
    pause
}

# Puts the server back in the state saved in /etc/seedtunnel, with the settings
# of the installed version: after an update, or if something was changed by
# hand. As when the installation runs again, only the files that change are
# written and only the services concerned are restarted.
apply_main() {
    local count=0
    banner
    section 'Applying the configuration'
    update_save_previous
    log_rotation_apply
    if vpn_installed; then
        vpn_apply
        count=$((count + 1))
    fi
    if seedbox_installed; then
        seedbox_apply
        count=$((count + 1))
    fi
    links_load
    if links_site_on; then links_apply; fi
    if firewall_enabled; then
        firewall_refresh
        count=$((count + 1))
    fi
    if [[ -r $BACKUP_PASSPHRASE_FILE ]]; then backup_auto_install_units; fi
    if ((count)); then
        ok 'Configuration up to date (seedtunnel %s).' "$APP_VERSION"
    else
        say 'Nothing to apply: neither VPN, nor seedbox, nor firewall.'
    fi
    update_log_installed
}
