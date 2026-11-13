# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.

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
