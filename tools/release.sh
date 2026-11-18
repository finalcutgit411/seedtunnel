#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  Builds and signs a release of seedtunnel on the maintainer's computer: the
#  signing key never goes to GitHub.
#
#    tools/release.sh X.Y.Z SIGNING_KEY [FOLDER]
#
#  SIGNING_KEY: the private release key (or its .pub file, with the private
#  key in ssh-agent). The tag vX.Y.Z must be an annotated tag signed by the
#  release key of lib/update.sh, its code must declare version X.Y.Z and its
#  commit must have passed the CI. The archive is built from the tag (git
#  archive), its checksums are signed, then everything is checked as
#  « seedtunnel update » checks it. The command that publishes the files is
#  shown, never run. FOLDER: where the files go (new folder; by default
#  seedtunnel-release-X.Y.Z in the temporary folder, never in the checkout).
# =============================================================================

RELEASE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/update.sh
. "$RELEASE_ROOT/lib/update.sh"

release_fail() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

# release_tag_check REPOSITORY VERSION — vX.Y.Z signed, code of that version
release_tag_check() {
    local repo=$1 version=$2 tag="v$2" object
    object=$(git -C "$repo" rev-parse --verify --quiet "refs/tags/$tag") || release_fail "tag $tag not found"
    APP_DIR=$repo update_verify_tag "$object" "$tag" \
        || release_fail "tag $tag is not an annotated tag signed by the release key of lib/update.sh"
    [[ $(git -C "$repo" show "$tag:lib/common.sh" | awk -F'"' '/^APP_VERSION="/ { print $2; exit }') == "$version" ]] \
        || release_fail "the code of $tag does not declare version $version"
}

# release_ci_check REPOSITORY VERSION — a successful CI run for the tagged commit
release_ci_check() {
    local repo=$1 commit runs
    command -v gh >/dev/null 2>&1 || release_fail 'gh is needed to check the CI'
    commit=$(git -C "$repo" rev-parse --verify "v$2^{commit}") || release_fail "tag v$2 not found"
    runs=$(cd "$repo" && gh run list --commit "$commit" --workflow ci.yml --json status,conclusion \
        --jq '[.[] | select(.status == "completed" and .conclusion == "success")] | length') \
        || release_fail 'cannot read the CI runs'
    [[ $runs =~ ^[0-9]+$ ]] && ((runs > 0)) || release_fail "no successful CI run for commit $commit"
}

# release_build REPOSITORY VERSION FOLDER KEY — archive, SHA256SUMS, signature
release_build() {
    local repo=$1 version=$2 out=$3 key=$4 name="seedtunnel-$2"
    [[ ! -e $out && ! -L $out ]] || release_fail "$out already exists"
    mkdir -p -- "$out" || release_fail "cannot create $out"
    # files 644 and folders 755 in the archive, whatever the local umask
    (umask 0022 && git -C "$repo" -c tar.umask=0022 archive --format=tar.gz \
        --prefix="$name/" -o "$out/$name.tar.gz" "refs/tags/v$version") || release_fail 'git archive failed'
    (cd "$out" && sha256sum "$name.tar.gz" >SHA256SUMS) || release_fail 'sha256sum failed'
    ssh-keygen -Y sign -f "$key" -n "$UPDATE_SIGNING_NAMESPACE" "$out/SHA256SUMS" || release_fail 'signing failed'
}

# release_verify FOLDER VERSION — the checks of « seedtunnel update », on a copy
release_verify() {
    local out=$1 version=$2 name="seedtunnel-$2" check modes
    check=$(mktemp -d) || release_fail 'cannot create a temporary folder'
    cp -- "$out/$name.tar.gz" "$out/SHA256SUMS" "$out/SHA256SUMS.sig" "$check/" || {
        rm -rf "$check"
        release_fail "missing files in $out"
    }
    modes=$(tar -tvzf "$check/$name.tar.gz" | awk 'substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w"')
    if [[ -n $modes ]] || ! update_verify_signature "$check" \
        || ! update_verify_checksum "$check" "$version" \
        || ! update_extract "$check/$name.tar.gz" "$check" "$version" \
        || ! update_check_syntax "$check/$name" \
        || [[ $(update_dir_version "$check/$name") != "$version" ]]; then
        rm -rf "$check"
        release_fail "the files in $out do not pass the checks of seedtunnel update"
    fi
    rm -rf "$check"
}

release_main() {
    set -Eeuo pipefail
    (($# == 2 || $# == 3)) || release_fail 'usage: tools/release.sh X.Y.Z SIGNING_KEY [FOLDER]'
    local version=$1 key=$2 out repo
    out=${3:-${TMPDIR:-/tmp}/seedtunnel-release-$1}
    update_version_valid "$version" || release_fail "invalid version: $version"
    [[ -f $key ]] || release_fail "signing key not found: $key"
    out=$(realpath -m -- "$out")
    APP_LOG=/dev/stderr
    release_tag_check "$RELEASE_ROOT" "$version"
    release_ci_check "$RELEASE_ROOT" "$version"
    release_build "$RELEASE_ROOT" "$version" "$out" "$key"
    release_verify "$out" "$version"
    repo=$(awk -F'"' '/^APP_REPO="/ { print $2; exit }' "$RELEASE_ROOT/lib/common.sh")
    printf '\nRelease %s built, signed and checked in %s.\n' "$version" "$out"
    printf 'Once the tag is pushed, publish it with:\n\n'
    printf '  gh release create v%s --repo %s --verify-tag --title "seedtunnel %s" --notes-from-tag \\\n' "$version" "$repo" "$version"
    printf '    %q %q %q\n' "$out/seedtunnel-$version.tar.gz" "$out/SHA256SUMS" "$out/SHA256SUMS.sig"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then release_main "$@"; fi
