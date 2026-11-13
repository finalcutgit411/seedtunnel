# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.

## [1.0.5] - 2026-11-13

### Security
- VPN: the clients can no longer reach each other, and nothing from outside the tunnel reaches them any more, except the answers to their own connections and their open port. Until now, the server forwarded to them any packet addressed to 10.8.0.x, from a machine of the network of the host for example. The rules are in the table of the VPN: with the firewall on or off. Policy « accept »: Docker and the other programs keep their traffic. `seedtunnel doctor` says when these rules are missing (rules loaded by an older version, until the next `seedtunnel apply`).
- Transmission: no program can run at the end of a download. The web interface could turn one on, run by the account of Transmission; `seedtunnel apply` turns it off again (and the two more of Transmission 4), and `seedtunnel doctor` says it. Transmission can no longer run anything from the folders where it or the SFTP user write.
- Transmission: its settings, which hold the hash of the password, were readable by every account after each stop (Transmission writes them again with its own umask). They are made private again right after, by its own account, and its folder is closed to the other accounts. `seedtunnel doctor` checks it.
- Links: a second download within the minute, refused by nginx, wrote the whole request (token included) to `error.log` of nginx. No longer.
- Files of seedtunnel: the archive of a version now has its folders in 755 and its files in 644 (775 and 664 until now), and an update sets them so whatever its archive says: only root can change what root runs.

### Changed
- `seedtunnel seedbox unban` refuses an address that is not one, and says when an address is not banned (nothing done).
- A VPN client name that differs from another only by the case of its letters (`PHONE` beside `phone`) is refused: Windows cannot keep both files in one folder.
- Turning the weekly backup off says that its passphrase is deleted from the server: the backups already made open only with the one written down.
- Restore on a new server: the frame says that the settings of the backup are put in place, no longer that a copy of the current ones is kept (there are none).
- Menu: a backup copied into `/root` or a home folder counts in the header and in « Latest », as in `seedtunnel backup list`.
- `seedtunnel doctor`: a clock not synchronized yet in the first 10 minutes after a start is said as being synchronized, not as a problem.
- `seedtunnel --version` (and `-V`), like `seedtunnel version`.
- Documentation: the security page says that the clients are isolated, and that every backup holds the passphrase of the weekly backup (whoever can open one backup can open the weekly ones).

### Fixed
- SFTP: after the removal of the seedbox then a restore, the documents of the account stayed owned by root, out of its reach. They are given back to the account when it is created again (never through a link, never a download it made a hard link to).
- The list of the fingerprints of the files written by seedtunnel no longer keeps the files deleted since.

## [1.0.4] - 2026-11-13

### Added
- Web interface: when Transmission does not answer (stopped because the disk is almost full, or starting again), a page « Transmission is not responding » in the colors of SeedTunnel, with what to do, instead of the « 502 Bad Gateway » of nginx. Shown only once the password is given.
- Backups: each one notes the format of the settings (format 1). A backup made by a newer version, in a format this one does not know, is refused before anything changes, with what to do: update seedtunnel first. Backups made before 1.0.4 count as format 1.
- The log says when the SFTP account is renamed (by a restore, or with new credentials); the report of `seedtunnel doctor --link` hides both names.

### Changed
- needrestart (Ubuntu) no longer runs during the installations of seedtunnel: a much shorter log. A new kernel waiting is still said by `seedtunnel doctor`.
- Tests: shellcheck looks for variables used but never set in the integration tests.

### Fixed
- Update: the lock goes straight to the new version. A seedtunnel command started at that very moment in another window could take it, and the update went back to the previous version for nothing. The installed version hands the lock over: from the next update on.

## [1.0.3] - 2026-11-13

### Added
- Backup / restore › My backups: the settings a finished restore kept aside (old keys of the VPN, passwords, passphrase) are said on a line, with « Delete the old settings » (a red frame, « no » by default). By command: `seedtunnel restore clean` (`--yes` without a terminal). Never during a restore cut short, whose way back they are. `seedtunnel doctor` and the end of a restore point to it, instead of an `rm -rf` to type.

### Changed
- Header of the screens: the full name of the server, its IPv4 address (read on the server itself: no outside site is asked) and its system. On a narrow screen (a phone), the system next to the version, the name and the address under the subtitle.
- Documentation: the README and the guide rewritten step by step for beginners, in English and in French, with new captures (backups, firewall rules).
- Site of the seedbox: any address that is neither the web interface nor a link (`/share` without its last `/`, a typo…) shows the page « Nothing here » once the password is given, instead of the « 404 Not Found » of nginx. The password is still asked first, and nothing of the default folder of nginx is served.
- The log says when an update is installed (« Update: 1.0.2 → 1.0.3 installed ») and when `seedtunnel update back` goes back to the previous version. Written by the new version: from this update on.

### Fixed
- Web interface on Transmission 4.0 (Ubuntu 24.04): the bars of the downloads stayed empty, the percentage done was not drawn. The pink is now a plain color there; Transmission 4.1 and later (Debian 13) keep the pink gradient. New capture of the web interface, with example torrents.

## [1.0.2] - 2026-11-13

### Security
- Restore: a backup holding a VPN client file with a name SeedTunnel never gives (a line break, a space, more than 15 characters…), or any file whose name holds a control character, is refused before anything changes. The name of a client goes into `wg0.conf`, where a line break could add a command run as root when the VPN starts. Backups made by SeedTunnel always pass: the names of the clients follow the same rule since 0.9.0. A file of this kind put there by hand is ignored: no client, nothing of it in `wg0.conf` nor in the NAT rules.

### Changed
- The folder of the links itself (`https://ADDRESS/share/`, on the site of the seedbox as on the site of the links) shows the page « Nothing here » too, without asking for a password, instead of the « 403 Forbidden » of nginx. The links keep their page « Link already used or expired ».

### Fixed
- `seedtunnel update` on a server where nothing is installed yet: the latest version is read without `jq`, which comes with the VPN or the seedbox. It said « Cannot find the latest version published ».

## [1.0.1] - 2026-11-13

### Changed
- Site of the links (VPN without a seedbox): an address that is not a link shows a page « Nothing here » in the colors of SeedTunnel, without its name, instead of the 404 of nginx.

## [1.0.0] - 2026-11-13

The version for everyday use: new screens in the terminal, download pages in the colors of SeedTunnel, one-time links without a seedbox, and the fixes found while testing it on real servers (Debian 12 and 13, Ubuntu 24.04 and 26.04). From 0.9.0: `sudo seedtunnel update`.

### License
- GNU General Public License, version 3 or later (GPL-3.0-or-later), instead of MIT. Version 0.9.0 stays under MIT.

### Added
- **One-time links with the VPN alone**: without a seedbox, the first link offers a small HTTPS site that serves the links and nothing else (nginx, ports 80 and 443; a Let's Encrypt certificate for a domain name pointing to the server, self-signed otherwise, with the fingerprint to check given with each link). VPN menu › Site of the links, or `seedtunnel vpn links [on|off]`. Removed with the VPN; a seedbox installed afterwards takes its place.
- **Backup / restore › My backups**: every backup, numbered, with the room they take and the free space of the disk; any of them downloaded through a one-time link or deleted after a red frame (« no » by default; it says when it is the last backup of the server, or a copy put there by hand). By command: `backup list`, `backup share NUMBER`, `backup delete NUMBER`. In the menu, the download is offered right after a backup is made (the entry « Download the latest backup » goes).
- **WinSCP profile** for SFTP, next to the FileZilla one: a file to import (Tools → Import Sites → INI file) with the fingerprint of the server, and the place of the key made by seedtunnel if there is one. By command: `seedtunnel seedbox sftp-config winscp`.
- **Firewall › Show the rules**, laid out: the ports open on the server, what is always allowed, the ports forwarded to the VPN clients; the raw nftables rules on demand.

### Changed
- **Screens of the terminal** in the style of the menus: the card of a client in a frame, then its QR code alone, then how to install the tunnel, the port for torrents and the kill switch; summaries in a green frame before an action (« before → after »); the DNS chosen like an entry of a menu; the backups to restore in a table; long texts wrapped to the width of the screen, an address or a command to copy never cut.
- **SFTP connection** explained: what an SSH key is, then « I have no key » (one is made for you) or « I already have a key » (what to paste; a private key pasted by mistake is named as such).
- **Download pages** dark, in the colors of SeedTunnel, with the next steps numbered. A link already used, expired or unknown shows a page that says so, in French and English, instead of the 404 of nginx.
- **Restore**: when the SFTP account of the server has another name than in the backup, it takes back the name of the backup (said before the question; a restore cut short gives the old name back), instead of stopping.
- Home screen: a recent backup without the weekly backup shows « manual », in yellow.
- After a restore from the menu, the menus speak the language of the backup.
- The fingerprint of a self-signed certificate is shown on two lines in 80 columns.

### Fixed
- `seedtunnel restore` without a file, in a terminal, stopped after the list of the backups (« Question asked outside interactive mode »).
- Restore: a text pasted while the passphrase was asked counted as many wrong passphrases. Now 3 tries, then the restore stops with nothing changed.
- Anonymized report: the SFTP account connected with WinSCP (Debian 13) was named as an administrator; on Ubuntu 26.04, an account named by needrestart was not hidden. The addresses of the DNS services of the menu stay readable (an address typed by hand is still hidden).

## [0.9.0] - 2026-11-12

First published version. SeedTunnel is meant for everyday use from version 1.0.0 on; until then, a 0.x version may still change how things look or work.

### What it does
- **WireGuard VPN**: up to 253 named clients, each with its QR code (it fits in a window of 80 columns) or a one-time download link (with the seedbox), its own open port (TCP and UDP) and no IPv6 leak. DNS of the clients to choose: Quad9 (default), Cloudflare, DNS4EU, AdGuard or your own addresses.
- **Seedbox**: Transmission 3 or 4 behind nginx in HTTPS, with a Let's Encrypt certificate renewed by itself (self-signed without a domain name), and a web interface in the colors of SeedTunnel. Files in SFTP, locked in the folder of the seedbox, with a password or SSH keys (a key ready for WinSCP and FileZilla). Transmission stopped cleanly before the disk is full.
- **Protection**: nftables firewall applied on trial (it undoes itself after 2 minutes unless a new SSH login proves you still have access), fail2ban, passwords kept as hashes, automatic security updates, hardened network settings of the kernel.
- **Maintenance**: diagnostics that give the command fixing each problem, and an anonymized report to share; encrypted backups, every week (the last 4 kept), restored on the same server or on a new one, from one system to another; verified updates, with a way back to the previous version.
- **Systems**: Debian 12 and 13, Ubuntu Server 24.04 and 26.04. English and French.
