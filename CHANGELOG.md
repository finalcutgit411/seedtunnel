# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.

## [1.0.9] - 2026-11-14

### Security
- Restore: the renewal file of the certificate in a backup is read as certbot reads it. A name between quotes (`"archive_dir"`), after a mark of UTF-8, or a section followed by a comment, is the same name for certbot, and passed the check: a backup made by someone else could send the renewals to other paths. These names are refused, like the plain ones with such values.
- Transmission: without the link of its folder, its settings in `/etc/transmission-daemon` are no longer followed when they are a link (that folder can be written by the group of Transmission), and root no longer reads them to merge them: the account of Transmission does. A link there could have made root copy a file of another program where Transmission reads it.

### Fixed
- Restore cut short: its way back (`bash …undo`) can be run again if it stops (`seedtunnel apply` failing, a power cut). Run again, it deleted the settings it had just put back. Its marker and its copies now go only once it went to the end, and `seedtunnel doctor` shows it as long as it is there. The command shown when there is no such script no longer deletes anything when run a second time.
- Site of the links installed before a link: a step that failed (settings that cannot be written, disk full) no longer ends with « Site of the links installed. » and the link. It stops there, and says why.

## [1.0.8] - 2026-11-14

### Added
- `seedtunnel doctor` checks five more things, without changing anything:
  - the settings of seedtunnel (keys of the VPN, passphrase, hashes of the passwords), its backups, the file of WireGuard and the passwords of the web interface: no other account than root can open them;
  - the files of seedtunnel, and the version kept for `seedtunnel update back`: no other account than root can change them (root runs them);
  - Transmission running right now cannot run anything from the folder of the data (its lock of systemd is in force);
  - logrotate takes the rule of seedtunnel: its log is cut every month;
  - no token of a link in clear in the logs of nginx.
- `seedtunnel apply` puts these rights back: settings and backups for root only, files of seedtunnel changeable by root only. A Transmission running without its lock is started again with it.

### Changed
- Tests: on GitHub, seedtunnel runs from a copy that belongs to root, as when installed from its archive.

## [1.0.7] - 2026-11-14

### Added
- Hosting panels: on a server with Plesk, cPanel, DirectAdmin, HestiaCP, VestaCP, CloudPanel, aaPanel, CyberPanel, Virtualmin or ISPConfig, seedtunnel installs nothing (VPN, seedbox, firewall, restore): these panels already run the web, the certificates and the security of the server, and rewrite their settings. `seedtunnel doctor` says it in red, and so does the block Firewall of the home screen when the panel came after seedtunnel.
- Another WireGuard VPN on the server (a file `/etc/wireguard/wg0.conf` not written by seedtunnel, an interface `wg0`, or the addresses `10.8.0.0/24` used by another interface): the VPN is neither installed nor restored. seedtunnel wrote over that file before, and the devices of the other VPN lost their access.
- A Transmission that seedtunnel did not install, or swizzin: the seedbox is neither installed nor restored. seedtunnel wrote over its settings (download folder, password, ports) before.

### Changed
- What stops seedtunnel before it changes anything is said the same way everywhere: what is in the way, why seedtunnel stops (« nothing was changed »), and « To go on: … ». A red frame « ✘ » in the menus, the same lines for the commands. This covers the hosting panels, another VPN, another Transmission, ufw, a system not supported (and Debian 11), a kernel without WireGuard (container VPS), ports 80/443 or the UDP port of the VPN taken; for the ports, each program is named with its ports (« a container of Docker » for docker-proxy).
- The pages of the server are no longer in French and in English at once. « Access denied » and « Nothing here », which anyone can see, are in English only (they say nothing of the language of the administrator). « Link already used or expired » and « Transmission is not responding », which only the administrator or someone who got one of the links sees, are in the language of seedtunnel, and follow it when it changes.
- Guide: a server without a hosting panel, the firewall of the provider to open, and « NAT » or IPv6-only VPS among the known limits.

## [1.0.6] - 2026-11-14

### Security
- Transmission: after a backup made with Transmission 4 (Debian 13, Ubuntu) was restored on Debian 12 (Transmission 3), the files it downloaded could be changed by every account of the server. Transmission 4 writes its umask as text (« "002" »), which Transmission 3 does not read: it put 0 in its place. The umask is now compared by its value, and written again for Transmission 3: `seedtunnel apply` puts a server already restored right, and `seedtunnel doctor` says when Transmission runs with such a umask. The files downloaded meanwhile keep their rights: `sudo find /srv/seedbox/complete /srv/seedbox/incomplete ! -type l -perm -o+w -exec chmod o-w {} +` closes them.
- `seedtunnel apply` also empties the names of the programs of Transmission (set through the web interface), not only their switch.
- Restore: a path that goes up out of the folders of seedtunnel (`etc/seedtunnel/../../…`) is refused before anything is extracted, with « Archive refused » (GNU tar stopped it, but later and less clearly).

### Fixed
- Docker on the same server: the VPN clients connected, but had no Internet (Docker refuses by default the traffic that crosses the server). seedtunnel now lets the VPN through, when the VPN is installed and at each `seedtunnel apply`: two rules in `DOCKER-USER`, the chain Docker keeps for the rules of the administrator, limited to the VPN (out to the Internet; back, the answers and the connections to the open ports of the clients). A service, `seedtunnel-docker`, puts them back each time Docker starts; they go away with the VPN. The protection of Docker stays, and its settings are not touched. Docker installed later: menu Firewall → `[4] Let the VPN through Docker`.
- `seedtunnel seedbox unban` right after a ban: a moment later, recidive banned the address again for a week (it reads the ban in the log of fail2ban). It is checked again a few seconds later, and unbanned again.
- Ubuntu: logrotate never cut `/var/log/seedtunnel.log` (« parent directory has insecure permissions »: there, `/var/log` can be written by the group syslog). The rule now says which account cuts it (`su root root`), and the log no longer grows without end.
- `seedtunnel seedbox sftp-key add` of a file that is not there: « File not found », no longer « Unexpected error ».
- `seedtunnel apply` with nothing to change rewrote `vpn.conf`, `seedbox.conf` and `written.sha256` with the same content. A file whose content does not change now keeps its date.

### Changed
- nginx no longer tells its version on port 80 either (`server_tokens off`, as on 443). The web interface gets one `X-Frame-Options` (Transmission sends its own: hidden).
- A subcommand given more arguments than it takes (`seedtunnel vpn list extra`) is refused before anything is done, as the commands already were.
- The full disk protection writes what it does (stopped, started again, not started) to `/var/log/seedtunnel.log` too, not only to the journal.
- `seedtunnel seedbox unban` says that fail2ban still counts the failures of the last 10 minutes: a few more mistakes within these 10 minutes ban the address again. Without an address, it says how to use it.
- `seedtunnel backup auto off` when the weekly backup is already off: says so, without warnings nor question.
- No backup found: says where they are looked for (directly in `/root`, or in a folder of `/home`).
- The comments of the file of a VPN client are in the language of seedtunnel.
- Before removing the seedbox, and before restoring a backup with a seedbox: « close WinSCP / FileZilla first ». Their automatic reconnections, while the SFTP account is gone, count as failures, and fail2ban banned the address (every SSH session from there cut).
- `seedtunnel seedbox sftp-config filezilla` no longer shows the address to paste into WinSCP.
- Removing the seedbox also removes `python3-systemd` when seedtunnel installed it (it was there for fail2ban), on its own: if another program needs it, only it is kept.
- Menu, firewall on trial: what to do is in a frame, said more clearly (a connection through the public address of the server is always enough; through the VPN, only if this window goes through the VPN too). « yes » before any new SSH connection: a red frame, with the time left.
- Menu, « Domain name and HTTPS certificate »: the address now, its certificate, when it ends and the public IP in a frame, then the two kinds of name and their certificate (also when the seedbox is installed).
- Frames: a line is no longer cut before « : » or inside « … » (French). The questions in French end with « : ».
- Menu, home screen: the block Firewall also turns yellow (« warning ») or red (« alert! ») when something around it goes wrong: Docker or another program that blocks the VPN clients, rules for Docker that a restart removes, nftables that empties the rules at boot, ufw on. The reason is below the blocks.
- Menu, home screen: a red block without a more precise word says « alert! » instead of « problem » (Firewall; Seedbox when nginx is stopped).
- Menu, screen Firewall, and `seedtunnel firewall status`: what is wrong is said in full, in a frame, with what to do. The line « Firewall on — open: … » is cut between words.
- Deleting the last backup made by the server says « the only backup made by this server » (one copied into a home folder may be older, or of another server).
- French: « Utilisation » for the help of `seedtunnel firewall` (it said « Usage »). The help says that `restore` without a file lists the backups in a terminal only.

## [1.0.5] - 2026-11-13

### Security
- VPN: the clients can no longer reach each other, and nothing from outside the tunnel reaches them any more, except the answers to their own connections and their open port. Until now, the server forwarded to them any packet addressed to 10.8.0.x, from a machine of the network of the host for example. The rules are in the table of the VPN: with the firewall on or off. Policy « accept »: Docker and the other programs keep their traffic. `seedtunnel doctor` says when these rules are missing (rules loaded by an older version, until the next `seedtunnel apply`).
- Transmission: no program can run at the end of a download. The web interface could turn one on, run by the account of Transmission; `seedtunnel apply` turns it off again (and the two more of Transmission 4), and `seedtunnel doctor` says it. Transmission can no longer run anything from the folders where it or the SFTP user write.
- Transmission: its settings, which hold the hash of the password, were readable by every account after each start and stop with Transmission 4.1 and later (Debian 13, Ubuntu 26.04: it writes them again with its own umask). They are made private again right after, by its own account, and its folder is closed to the other accounts. `seedtunnel doctor` checks it.
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
