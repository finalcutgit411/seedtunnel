#!/usr/bin/env bash
# =============================================================================
#  seedtunnel — update, and applying the configuration again
#
#  Update: downloads the latest version published on GitHub, checks its
#  SHA-256 checksum, then replaces the folder of the script (or « git
#  checkout » of the latest tag if the script was installed with git). The
#  new version then applies its own fixes (« seedtunnel apply »); if that
#  fails, the previous version comes back.
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

update_from_release() {
    local tag version tmp base
    tag=$(curl -fsSL --max-time 15 "https://api.github.com/repos/$APP_REPO/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null || true)
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
        rm -rf "$previous"
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

# After a failed update: the installed version applies its configuration again
update_back_to_previous() {
    warn 'Version %s could not apply the configuration: back to version %s.' "$1" "$APP_VERSION"
    if ! "$APP_DIR/seedtunnel.sh" apply >>"$APP_LOG" 2>&1; then
        die 'Update cancelled: the files of version %s are back, but putting the configuration back into service failed too (details in %s). Run « seedtunnel doctor », then « seedtunnel apply ».' "$APP_VERSION" "$APP_LOG"
    fi
    die 'Update cancelled, version %s kept (details in %s).' "$APP_VERSION" "$APP_LOG"
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
    # Newest published version: a vX.Y.Z tag only, of seedtunnel (older tags
    # of the repository belong to finalcut), whose code says the same version
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
    section 'UPDATING SEEDTUNNEL'
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
    section 'APPLYING THE CONFIGURATION'
    if vpn_installed; then
        vpn_apply
        count=$((count + 1))
    fi
    if seedbox_installed; then
        seedbox_apply
        count=$((count + 1))
    fi
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
}
