#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  seedtunnel — version acquisition, switching and rollback
#
#  Update: selects a published version eligible for the installed version,
#  checks the signature of its checksums with the release key written below,
#  then its SHA-256 checksum, then replaces the folder of the script (or « git
#  checkout » of its fetched commit, whose tag must be signed with the same
#  key, if installed with git). The
#  new version then applies its own fixes (« seedtunnel apply »); if that
#  fails, the previous version comes back.
#
#  The version replaced is kept in APP_DIR.old (one only):
#  « seedtunnel update back » puts it back.
# =============================================================================

# Release key (Ed25519, kept offline, never on GitHub): it signs the SHA256SUMS
# of each release and each Git tag. A new key only comes with a version signed
# by the key in place. Public key: nothing secret here.
UPDATE_SIGNING_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIcibv00gKCrJdL9NYksnXPaA+EWcszD8s5J4wk7X1MM seedtunnel-release'
UPDATE_SIGNER=seedtunnel-release
# ssh-keygen namespace of the release signature (Git tags use « git »)
UPDATE_SIGNING_NAMESPACE=seedtunnel-release

# Public versions: X.Y.Z, decimal numbers without leading zeros.
update_version_valid() {
    [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

# Compare decimal strings without converting them to fixed-width integers.
version_greater() {
    local left=$1 right=$2 i
    local -a a b
    update_version_valid "$left" && a=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}") || return 1
    update_version_valid "$right" && b=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}") || return 1
    for i in 0 1 2; do
        [[ ${a[i]} != "${b[i]}" ]] || continue
        if ((${#a[i]} != ${#b[i]})); then ((${#a[i]} > ${#b[i]})); else [[ ${a[i]} > ${b[i]} ]]; fi
        return $?
    done
    return 1
}

update_verify_checksum() {
    (cd "$1" && awk -v file="seedtunnel-$2.tar.gz" '
        NF == 2 && $2 == file && length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {print; n++}
        END {if (n != 1) exit 1}
    ' SHA256SUMS | sha256sum -c -)
}

# update_allowed_signers FILE — the release key, for ssh-keygen and git only:
# a signature made for another namespace (or by another key) is refused
update_allowed_signers() {
    printf '%s namespaces="%s,git" %s\n' "$UPDATE_SIGNER" "$UPDATE_SIGNING_NAMESPACE" "$UPDATE_SIGNING_KEY" >"$1"
}

# update_verify_signature FOLDER — SHA256SUMS.sig is a signature of SHA256SUMS
# by the release key: without it, the checksums only prove the transport
update_verify_signature() {
    local folder=$1
    [[ -f $folder/SHA256SUMS && ! -L $folder/SHA256SUMS && -f $folder/SHA256SUMS.sig && ! -L $folder/SHA256SUMS.sig ]] || return 1
    update_allowed_signers "$folder/allowed_signers" || return 1
    ssh-keygen -Y verify -f "$folder/allowed_signers" -I "$UPDATE_SIGNER" -n "$UPDATE_SIGNING_NAMESPACE" \
        -s "$folder/SHA256SUMS.sig" <"$folder/SHA256SUMS"
}

# update_verify_tag OBJECT TAG — OBJECT is an annotated tag named TAG inside
# (not only fetched under that name), signed by the release key
update_verify_tag() {
    local object=$1 tag=$2 signers
    [[ $(git -C "$APP_DIR" cat-file -t "$object" 2>>"$APP_LOG") == tag ]] || return 1
    [[ $(git -C "$APP_DIR" cat-file tag "$object" 2>>"$APP_LOG" | sed -n '/^$/q;s/^tag //p') == "$tag" ]] || return 1
    signers=$(mktemp) || return 1
    update_allowed_signers "$signers" || {
        rm -f "$signers"
        return 1
    }
    git -C "$APP_DIR" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile="$signers" \
        verify-tag "$object" >>"$APP_LOG" 2>&1
    local status=$?
    rm -f "$signers"
    return "$status"
}

# update_download SECONDS FILE URL — HTTPS only, redirects included, in a
# bounded time (a blocked network never holds the lock for ever)
update_download() {
    curl -fsSL --proto =https --proto-redir =https --max-time "$1" -o "$2" "$3"
}

update_check_syntax() {
    local file
    for file in "$1"/seedtunnel.sh "$1"/lib/*.sh "$1"/lang/*.sh; do
        bash -n "$file" || return 1
    done
}

# update_archive_safe ARCHIVE VERSION — only folders and plain files, all under
# seedtunnel-VERSION/, no absolute path and no « .. » (links are refused: the
# code has none, and one could point the new version outside its folder)
update_archive_safe() {
    local prefix="seedtunnel-$2" name type count=0
    while IFS= read -r name; do
        count=$((count + 1))
        [[ $name == "$prefix/" || $name == "$prefix/"* ]] || return 1
        [[ /$name/ != */../* ]] || return 1
    done < <(tar -tzf "$1") || return 1
    ((count > 0)) || return 1
    while IFS= read -r type; do
        [[ $type == [-d]* ]] || return 1
    done < <(tar -tvzf "$1") || return 1
}

# update_extract ARCHIVE FOLDER VERSION — checked entries, owned by root (the
# user who extracts) whatever the archive says, and that only root can change
# (an archive with folders in 775 and files in 664 would let a member of the
# group root change what root runs)
update_extract() {
    update_archive_safe "$1" "$3" || return 1
    tar --no-same-owner --no-same-permissions -xzf "$1" -C "$2" && chmod -R go-w -- "$2/seedtunnel-$3"
}

# Return a single published release tag for both installation methods, or
# nothing when the valid listing holds no eligible release (none published).
# No selection is returned until every page has been validated. The bounded
# scan fails closed rather than treating a truncated listing as complete.
update_release_select() {
    local page body count rows tag prerelease version best="" minimum=1.0.0
    command -v jq >/dev/null 2>&1 || die 'Updates require jq. Install jq, then retry; no update was attempted.'
    command -v ssh-keygen >/dev/null 2>&1 || die 'Updates require ssh-keygen (package openssh-client) to check signatures. Install it, then retry; no update was attempted.'
    update_version_valid "$APP_VERSION" || die 'Unsupported installed version %s; update cancelled.' "$APP_VERSION"
    if [[ $APP_VERSION != "$minimum" ]] && ! version_greater "$APP_VERSION" "$minimum"; then
        die 'Updates require version 1.0.0 or newer. This checkout is version %s; no update was attempted.' "$APP_VERSION"
    fi
    for ((page = 1; page <= 20; page++)); do
        body=$(curl -fsSL --proto =https --proto-redir =https --max-time 15 "https://api.github.com/repos/$APP_REPO/releases?per_page=100&page=$page" 2>>"$APP_LOG") \
            || die 'Cannot read published releases from github.com/%s; update cancelled.' "$APP_REPO"
        count=$(jq -ser '
            if length == 1 and (.[0] | type == "array") then .[0] else error("expected one release array") end |
            if length <= 100 and all(.[];
                type == "object" and (.tag_name | type == "string") and
                (.draft | type == "boolean") and (.prerelease | type == "boolean") and
                (.published_at == null or (.published_at | type == "string")))
            then length else error("invalid release metadata") end
        ' <<<"$body" 2>>"$APP_LOG") \
            || die 'Invalid release metadata from github.com/%s; update cancelled.' "$APP_REPO"
        rows=$(jq -r '.[] | select(.draft == false and (.published_at | type == "string" and length > 0)) |
            [.tag_name, .prerelease] | @tsv' <<<"$body") \
            || die 'Invalid release metadata from github.com/%s; update cancelled.' "$APP_REPO"
        while IFS=$'\t' read -r tag prerelease; do
            [[ $tag == v* ]] || continue
            version=${tag#v}
            update_version_valid "$version" || continue
            [[ $version == "$minimum" ]] || version_greater "$version" "$minimum" || continue
            [[ $prerelease == false ]] || continue
            if [[ -z $best ]] || version_greater "$version" "${best#v}"; then best=$tag; fi
        done <<<"$rows"
        if ((count < 100)); then
            printf '%s' "$best"
            return 0
        fi
    done
    die 'The release list is incomplete; update cancelled.'
}

# The checksum/syntax do not prove that the code declares the selected version.
update_candidate_check() {
    local folder=$1 version=$2
    [[ -d $folder && ! -L $folder && -f $folder/seedtunnel.sh && ! -L $folder/seedtunnel.sh &&
        -f $folder/lib/common.sh && ! -L $folder/lib/common.sh && $(update_dir_version "$folder") == "$version" ]] \
        || die 'The downloaded code does not match release %s; update cancelled.' "$version"
}

# update_none_published TAG — no eligible release at all: nothing to update,
# which is not an error (a failed or invalid listing never gets here)
update_none_published() {
    [[ -z $1 ]] || return 1
    ok 'No published version is available: seedtunnel is up to date (version %s).' "$APP_VERSION"
}

update_from_release() {
    local tag version tmp base
    tag=$(update_release_select) || return $?
    update_none_published "$tag" && return 0
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
    run "$(t 'Downloading seedtunnel %s' "$version")" update_download 300 "$tmp/seedtunnel-$version.tar.gz" "$base/seedtunnel-$version.tar.gz"
    run 'Downloading the checksums' update_download 30 "$tmp/SHA256SUMS" "$base/SHA256SUMS"
    run 'Downloading the signature' update_download 30 "$tmp/SHA256SUMS.sig" "$base/SHA256SUMS.sig"
    printf '  %s… ' "$(t 'Checking the signature')"
    if ! update_verify_signature "$tmp" >>"$APP_LOG" 2>&1; then
        printf '%s%s%s\n\n' "$C_RED" "$(t 'failed')" "$C_RESET"
        die 'Release %s is not signed by the seedtunnel release key; update cancelled.' "$version"
    fi
    printf '%s%s%s\n' "$C_GREEN" "$(t 'ok')" "$C_RESET"
    run 'Checking the SHA-256 checksum' update_verify_checksum "$tmp" "$version"
    run 'Extracting' update_extract "$tmp/seedtunnel-$version.tar.gz" "$tmp" "$version"
    run 'Checking the syntax' update_check_syntax "$tmp/seedtunnel-$version"
    update_candidate_check "$tmp/seedtunnel-$version" "$version"
    update_switch "$tmp/seedtunnel-$version" "$version"
}

# While the folders are renamed, an interruption (Ctrl+C, closed session)
# would leave no seedtunnel in APP_DIR: it waits until they are in place. A
# power cut still can: the installed code is then in APP_DIR.previous.
update_signals_hold() {
    UPDATE_SIGNALS=$(trap -p INT TERM HUP QUIT)
    trap '' INT TERM HUP QUIT
}

update_signals_release() {
    trap - INT TERM HUP QUIT
    eval "${UPDATE_SIGNALS-}"
    UPDATE_SIGNALS=""
}

# Puts the new version (folder $1) in place of the installed one, which is kept
# until the new one has applied the configuration; if that fails, the installed
# version comes back. Renaming: the running script keeps its files open.
# « mv -T »: never moves a folder into another one by mistake.
update_switch() {
    local new=$1 version=$2 previous="$APP_DIR.previous"
    # left by an update that did not finish: it may be the only working copy
    [[ ! -e $previous && ! -L $previous ]] \
        || die '%s exists: an earlier update did not finish. If seedtunnel works, delete it (rm -rf %s), then update again.' "$previous" "$previous"
    update_recovery_path_free "$APP_DIR.failed"
    update_recovery_path_free "$APP_DIR.old.tmp"
    update_old_slot_safe || die 'Update cancelled: saved code could not be preserved (details in %s).' "$APP_LOG"
    update_signals_hold
    mv -T "$APP_DIR" "$previous" 2>>"$APP_LOG" \
        || die 'The new version could not be put in place: version %s kept (details in %s).' "$APP_VERSION" "$APP_LOG"
    if ! mv -T "$new" "$APP_DIR" 2>>"$APP_LOG"; then
        mv -T "$previous" "$APP_DIR" 2>>"$APP_LOG" \
            || die 'The new version could not be put in place, nor the previous one put back (details in %s). By hand:  mv %s %s' "$APP_LOG" "$previous" "$APP_DIR"
        die 'The new version could not be put in place: version %s kept (details in %s).' "$APP_VERSION" "$APP_LOG"
    fi
    update_signals_release
    if update_apply_new; then
        if ! update_keep_old "$previous"; then
            die 'Version %s was applied, but the previous code could not be stored in %s. Recovery files were kept (details in %s).' "$version" "$APP_DIR.old" "$APP_LOG"
        fi
        ok 'seedtunnel updated to version %s (see %s).' "$version" "$APP_DIR/CHANGELOG.md"
        exit 0
    fi
    update_recovery_path_free "$APP_DIR.failed"
    update_signals_hold
    if ! { mv -T "$APP_DIR" "$APP_DIR.failed" && mv -T "$previous" "$APP_DIR"; } 2>>"$APP_LOG"; then
        die 'Version %s could not apply the configuration, and version %s could not be put back (details in %s). By hand:  mv %s %s.failed ; mv %s %s ; seedtunnel apply' "$version" "$APP_VERSION" "$APP_LOG" "$APP_DIR" "$APP_DIR" "$previous" "$APP_DIR"
    fi
    update_signals_release
    update_back_to_previous "$version"
}

# The new version applies the configuration, so that its fixes take effect. It
# runs as a process of its own.
update_apply_new() {
    echo
    update_run_apply
}

# update_run_apply — « apply » of the version now in APP_DIR, as a process of
# its own. The lock goes over to it without ever being free (see take_lock):
# a command started meanwhile in another window is refused, instead of taking
# the lock and making the update go back for nothing. A version that does not
# know this (an older one) gets the lock let go just before, as it expects.
update_run_apply() {
    # Inherit a caller's operation lease even when its scoped variable was not
    # exported. The child validates it; local export does not leak to callers.
    local -x OPERATION_FD=${OPERATION_FD-}
    if [[ /proc/self/fd/9 -ef $APP_LOCK ]] && grep -q 'SEEDTUNNEL_LOCK_HANDED_OVER' "$APP_DIR/lib/common.sh" 2>/dev/null; then
        SEEDTUNNEL_LOCK_HANDED_OVER=1 "$APP_DIR/seedtunnel.sh" apply
    else
        exec 9>&-
        "$APP_DIR/seedtunnel.sh" apply
    fi
}

# After a failed update (or a failed way back: « back »): the installed
# version applies its configuration again
update_back_to_previous() {
    warn 'Version %s could not apply the configuration: back to version %s.' "$1" "$APP_VERSION"
    if ! update_run_apply >>"$APP_LOG" 2>&1; then
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

# A pre-existing working/recovery artifact may be the only useful copy.
update_recovery_path_free() {
    [[ ! -e $1 && ! -L $1 ]] \
        || die 'Recovery path %s already exists. Inspect or move it before retrying; nothing was removed.' "$1"
}

# The .old slot is managed code, not an arbitrary directory or symlink.
# Recognise historical layout without executing it; this is not authentication.
update_old_slot_safe() {
    local old="$APP_DIR.old" version
    [[ -e $old || -L $old ]] || return 0
    if [[ -d $old && ! -L $old && -f $old/seedtunnel.sh && ! -L $old/seedtunnel.sh &&
        -f $old/lib/common.sh && ! -L $old/lib/common.sh ]]; then
        version=$(update_dir_version "$old")
        if [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([+~.-][A-Za-z0-9._+~-]+)?$ ]]; then return 0; fi
    fi
    err 'Refusing to replace unrecognised saved code at %s.' "$old"
    return 1
}

# Only the managed .old slot is rotated. A failed move never deletes SOURCE.
update_keep_old() {
    [[ -d $1 && ! -L $1 && -f $1/seedtunnel.sh && ! -L $1/seedtunnel.sh ]] || return 1
    update_old_slot_safe || return 1
    rm -rf -- "$APP_DIR.old" || return $?
    mv -T -- "$1" "$APP_DIR.old" 2>>"$APP_LOG"
}

# During an update made by a version that deletes the version it replaces
# once « apply » worked: a copy of it is kept, so that the
# way back works from the first update on. Run by « apply ».
update_save_previous() {
    local version stage="$APP_DIR.old.tmp"
    [[ -f $APP_DIR.previous/seedtunnel.sh && ! -d $APP_DIR/.git ]] || return 0
    version=$(update_dir_version "$APP_DIR.previous")
    [[ -n $version ]] || return 0
    version_greater "$APP_VERSION" "$version" || return 0
    update_recovery_path_free "$stage"
    update_old_slot_safe || die 'Update cancelled: saved code could not be preserved (details in %s).' "$APP_LOG"
    if ! cp -a -- "$APP_DIR.previous" "$stage" 2>>"$APP_LOG" \
        || ! rm -rf -- "$APP_DIR.old" \
        || ! mv -T -- "$stage" "$APP_DIR.old" 2>>"$APP_LOG"; then
        die 'Cannot preserve the previous code in %s. Recovery files were kept (details in %s).' "$stage" "$APP_LOG"
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
    update_old_slot_safe || die 'Update cancelled: saved code could not be preserved (details in %s).' "$APP_LOG"
    version=$(update_old_version)
    [[ -n $version ]] || die 'No previous version kept: it is kept from the next update on.'
    danger "$(t 'Back to version %s' "$version")" \
        "$(t 'Version %s replaces version %s and applies the same settings again; if that fails, version %s comes back.' "$version" "$newer" "$newer")"
    if ! confirm "$(t 'Go back to version %s?' "$version")" n; then return 0; fi
    echo
    run 'Checking the syntax' update_check_syntax "$APP_DIR.old"
    [[ ! -e $previous && ! -L $previous ]] \
        || die '%s exists: an earlier update did not finish. If seedtunnel works, delete it (rm -rf %s), then update again.' "$previous" "$previous"
    update_signals_hold
    mv -T "$APP_DIR" "$previous" 2>>"$APP_LOG" \
        || die 'Version %s could not be put in place: version %s kept (details in %s).' "$version" "$newer" "$APP_LOG"
    if ! mv -T "$APP_DIR.old" "$APP_DIR" 2>>"$APP_LOG"; then
        mv -T "$previous" "$APP_DIR" 2>>"$APP_LOG" \
            || die 'Version %s could not be put in place, nor version %s put back (details in %s). By hand:  mv %s %s' "$version" "$newer" "$APP_LOG" "$previous" "$APP_DIR"
        die 'Version %s could not be put in place: version %s kept (details in %s).' "$version" "$newer" "$APP_LOG"
    fi
    update_signals_release
    # an older version rewrites files without keeping their fingerprints
    written_forget
    if update_apply_new; then
        rm -rf "$previous"
        log_title 'Back to version %s (version %s removed)' "$version" "$newer"
        ok 'Back to version %s (version %s comes back with  seedtunnel update).' "$version" "$newer"
        exit 0
    fi
    # the older version failed: the newer one comes back, and stays kept
    update_signals_hold
    if ! { mv -T "$APP_DIR" "$APP_DIR.old" && mv -T "$previous" "$APP_DIR"; } 2>>"$APP_LOG"; then
        die 'Version %s could not apply the configuration, and version %s could not be put back (details in %s). By hand:  mv %s %s.old ; mv %s %s ; seedtunnel apply' "$version" "$newer" "$APP_LOG" "$APP_DIR" "$APP_DIR" "$previous" "$APP_DIR"
    fi
    update_signals_release
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
    local tag object candidate previous version status
    status=$(git -C "$APP_DIR" status --porcelain 2>>"$APP_LOG") \
        || die 'Cannot inspect the installed Git checkout; update cancelled.'
    [[ -z $status ]] || die 'The folder %s has local changes: update cancelled.' "$APP_DIR"
    tag=$(update_release_select) || return $?
    update_none_published "$tag" && return 0
    if ! version_greater "${tag#v}" "$APP_VERSION"; then
        ok 'seedtunnel is up to date (version %s).' "$APP_VERSION"
        return 0
    fi
    # Fetch the selected published tag from the expected repository, never a
    # local tag or an unrelated origin. Pin the checkout to the fetched commit.
    run 'Fetching the published versions' git -C "$APP_DIR" fetch --quiet --no-tags "https://github.com/$APP_REPO.git" "refs/tags/$tag"
    object=$(git -C "$APP_DIR" rev-parse --verify FETCH_HEAD 2>>"$APP_LOG") \
        || die 'Cannot resolve the published Git tag %s; update cancelled.' "$tag"
    printf '  %s… ' "$(t 'Checking the signature')"
    if ! update_verify_tag "$object" "$tag"; then
        printf '%s%s%s\n\n' "$C_RED" "$(t 'failed')" "$C_RESET"
        die 'The Git tag %s is not signed by the seedtunnel release key; update cancelled.' "$tag"
    fi
    printf '%s%s%s\n' "$C_GREEN" "$(t 'ok')" "$C_RESET"
    candidate=$(git -C "$APP_DIR" rev-parse --verify "$object^{commit}" 2>>"$APP_LOG") \
        || die 'Cannot resolve the published Git tag %s; update cancelled.' "$tag"
    version=$(update_tag_version "$candidate")
    if [[ $version != "${tag#v}" ]] || ! git -C "$APP_DIR" cat-file -e "$candidate:seedtunnel.sh" 2>>"$APP_LOG"; then
        die 'The downloaded code does not match release %s; update cancelled.' "${tag#v}"
    fi
    say 'Installed version: %s → available: %s' "$APP_VERSION" "${tag#v}"
    if ! confirm 'Update?' y; then return 0; fi
    previous=$(git -C "$APP_DIR" rev-parse HEAD)
    run "$(t 'Switching to version %s' "${tag#v}")" git -C "$APP_DIR" -c advice.detachedHead=false checkout --quiet "$candidate"
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
