#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared storage policy with explicit human/engine identities.
# Load after common/i18n. Sourcing only defines functions.

# Biggest local partition; if it is « / », /srv/seedbox is used
storage_default_dir() {
    local mount
    mount=$(df -lP -x tmpfs -x devtmpfs -x overlay -x squashfs -x vfat 2>/dev/null \
        | awk 'NR > 1 { print $4, $6 }' | sort -nr | awk 'NR == 1 { print $2 }' || true)
    case $mount in
        "" | / | /boot*) printf '/srv/seedbox' ;;
        *) printf '%s/seedbox' "${mount%/}" ;;
    esac
}

# sshd requires every folder in the path of the SFTP chroot to belong to root
# and to be writable by nobody else.
storage_check_chroot_path() {
    local path=$1 current="" part owner mode
    local -a parts
    if [[ ! $path =~ ^(/[A-Za-z0-9._-]+)+$ || $path == *..* ]]; then
        warn 'Invalid path: /folder/subfolder (letters, digits, . _ -).'
        return 1
    fi
    case $path in
        /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /media | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
            warn 'Choose a subfolder, not a system folder (e.g. %s/seedbox).' "$path"
            return 1
            ;;
    esac
    IFS=/ read -r -a parts <<<"${path#/}"
    for part in "${parts[@]}"; do
        current+="/$part"
        # the rest will be created by the script (root, 755)
        [[ -e $current ]] || break
        if [[ ! -d $current ]]; then
            warn '%s exists but is not a folder.' "$current"
            return 1
        fi
        read -r owner mode < <(stat -L -c '%u %a' "$current")
        if ((owner != 0 || (8#$mode & 8#022))); then
            warn '%s must belong to root and be writable only by root (needed by the locked SFTP).' "$current"
            return 1
        fi
    done
    return 0
}

# The folders storage_apply creates in the data folder: the only ones that
# « seedbox uninstall --purge-data » deletes
STORAGE_PARTS=(complete incomplete watch documents)

# storage_check_data_content PATH — the data folder becomes the root of the
# locked SFTP and the folder the engine may write to: a folder that exists
# (/var/lib, /usr/local…) must hold nothing but the folders seedtunnel creates
# there (left by a removal that kept the data, or those of this server at a
# restore), and lost+found at the root of a disk. Each of them a real folder:
# storage_apply would give the target of a link to the engine.
storage_check_data_content() {
    local path=$1 entry name
    [[ -d $path ]] || return 0
    while IFS= read -r -d '' entry; do
        name=${entry##*/}
        case $name in
            complete | incomplete | watch | documents | lost+found)
                [[ -d $entry && ! -L $entry ]] && continue
                ;;
        esac
        warn '%s holds files that seedtunnel did not create: choose a new or empty folder.' "$path"
        return 1
    done < <(find "$path" -mindepth 1 -maxdepth 1 -print0)
    return 0
}

# --- AppArmor (Ubuntu 26.04) --------------------------------------------------------
# Ubuntu 26.04 confines transmission-daemon with an AppArmor profile that only
# lets it write to /var/lib/transmission-daemon/downloads: in the data folder
# of the seedbox, every download failed (« Permission denied »), although its
# permissions were right. The profile includes local/transmission-daemon for
# the additions of the site: seedtunnel writes there the data folder, and only
# it, then reloads the profile. Without this profile (Debian, Ubuntu 24.04):
# nothing. AppArmor itself is left as it is.
storage_apply() {
    local data_dir=$1 human=$2 engine_user=$3 engine_group=$4
    local documents="$data_dir/documents" give_back=0
    install -d -m 755 -o root -g root "$data_dir"
    # setgid (the 2 of 2775): everything created inside belongs to the group of
    # the engine, so the SFTP user can read and delete the files.
    install -d -m 2775 -o "$engine_user" -g "$engine_group" \
        "$data_dir/complete" "$data_dir/incomplete" "$data_dir/watch"
    # documents kept when the account was deleted (they then belong to root):
    # given back to the account created again (restore, new installation)
    if [[ -d $documents && ! -L $documents && $(stat -c %U -- "$documents" 2>/dev/null) != "$human" ]]; then
        give_back=1
    fi
    install -d -m 700 -o "$human" -g "$human" "$documents"
    if ((give_back)); then
        run "$(t 'Giving the documents back to %s' "$human")" storage_documents_owner "$data_dir" "$human:$human" root
    fi
}

# storage_documents_owner DATA OWNER FROM — gives to OWNER what documents/ holds:
# the files of FROM, and the others that have no other name elsewhere (a hard
# link made by SFTP to a download: changing it would change the download).
# Never through a link: find does not follow them, chown -h changes the link
# itself.
storage_documents_owner() {
    local data_dir=$1 owner=$2 previous=$3
    find "$data_dir/documents" -xdev \( -type d -o -links 1 -o -user "$previous" \) -exec chown -h "$owner" {} +
}
