# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.

## [2.1.0] - 2026-11-07

### Added
- **Back to the previous version**: an update now keeps the version it replaced (in `/opt/seedtunnel.old`, one only). `seedtunnel update back` puts it back, after a question answered « no » by default; it applies the settings again, and if that fails, the newer version comes back. In the menu, « Update seedtunnel » offers it when a version is kept. Already works for the update from 2.0.0 to 2.1.0.
- **BitTorrent port seen from the Internet**: `seedtunnel doctor` asks the test service of Transmission whether the port of the seedbox can be reached. Closed, it points to the firewall of the hosting provider (at OVH: the « Edge Network Firewall » of the control panel). If the service does not answer, the port is said « not tested », without a warning.
- **SFTP password**: shown in yellow in the menus while it is allowed (an SSH key is safer). `seedtunnel doctor` warns once there is an SSH key, the password being of no use then: `seedtunnel seedbox sftp-password off`.

### Changed
- **The log no longer grows without end**: `/var/log/seedtunnel.log` is cut every month by logrotate, the last 6 months kept, compressed. Set up by the installation and by `seedtunnel apply` (so by the update too).
- **Clearer log**: stopping a service (firewall, VPN, Transmission, weekly backup, full disk protection) writes its own title; its « Removed … » line looked like part of the step before.

## [2.0.0] - 2026-11-07

A new look for the menus. The commands, the configuration file and what seedtunnel does on the server do not change.

### Changed
- **New interface of the menus**, in pure bash (nothing to install): a header with the name of the server and its version of Debian, a thin line, where you are (« seedtunnel › VPN › Clients »), aligned values, menu keys as `[1]`, pink as the color of seedtunnel. Readable without colors (`NO_COLOR` is honored), and fitted to the width of the window: nothing goes past the edge, accents and symbols no longer shift the columns.
- **Home screen**: five blocks with the real state of the server — VPN (connected clients), seedbox, firewall, disk (used part, free space), backup (date of the last one) — in green, yellow or red. On a narrow window (under 80 columns), an aligned list instead. The menu goes on two columns when there is room.
- **Same keys everywhere**: `B` (or an empty answer) goes back, `R` refreshes, `Q` leaves seedtunnel from any menu (in 1.2.x, `Q` went back). After an action: « Enter ↵ back · Q quit ».
- **An error in a menu no longer leaves seedtunnel**: its message stays on the screen and Enter goes back to the menu.
- **Actions that cannot be undone** (revoke a client, remove the VPN or the seedbox, restore a backup, turn the firewall off, restart the server) are shown in a red frame; the question still answers « no » by default.
- `seedtunnel vpn list`: an aligned table. The titles of the commands (in capitals) follow the new names of the screens, and a few warnings are added before the actions above.
- `tools/preview.sh`: the screens with example data, to check the look in your own terminal without installing anything.

### Fixed
- **Report to ask for help**: version numbers of packages (such as `4.23.9.0-2+b1`) were taken for IP addresses and replaced.
- **Log**: removing the VPN, or turning the firewall off, wrote a harmless but alarming « Error: No such file or directory » (a table already gone was deleted a second time).

## [1.2.8] - 2026-11-07

After a cross-module review: the restore on a server that already has seedtunnel, and two new tools.

### Security
- **Restore and the SFTP account**: restoring a backup with another SFTP account than the seedbox of the server left the old account with its password, but **without its SFTP restrictions** (SSH tunnels possible when SSH accepts passwords). And on a new server, an account of the backup that already existed (an administration account of the same name) was taken over: password changed, shut in SFTP. The restore now checks the account as the installation does, **before anything is replaced**, and stops, saying what to do. On a new server, the web ports 80/443 are checked too.

### Added
- **`seedtunnel firewall rules`** (and « Show the rules » in the firewall menu): the rules nftables really has loaded, in words, and the ports forwarded to each VPN client. What differs from the settings is pointed out; the raw rules can be shown too.
- **Report to ask for help**: `seedtunnel doctor --link`, or the question at the end of the diagnostics in the menu. The diagnostics and the end of the log in one file, sent by a one-time link (saved in your home folder without a seedbox). Domain, name of the server, public IP addresses, SFTP account, SSH keys and names of the VPN clients are replaced by generic words; the ports and the addresses inside the VPN stay. No password, passphrase or key: the automatic tests check it after a full installation.

### Fixed
- **Restore of a backup without a part the server has**: a VPN or a seedbox of the server missing from the backup kept running without seedtunnel knowing it (the VPN no longer started after a restart, the full disk protection stopped, the seedbox could no longer be removed). The restore now refuses first, saying what to do. A firewall of the server missing from the backup stays on, its rules made again for the settings restored (it used to vanish at the next restart while still loaded).
- **Restore cut short** (power cut): the next runs said nothing. `seedtunnel doctor` and the menu now point it out, with the way back.
- **Firewall at boot**: if `nftables.service` is on, its « flush ruleset » could come after the firewall of seedtunnel and remove it. The firewall is now loaded after it.

## [1.2.7] - 2026-11-06

### Fixed
- **Restore and weekly backup**: restoring a backup made before the weekly backup was turned on removed its passphrase (the settings restored had none), while its timer, which is not part of a backup, kept running: every weekly backup would have failed, without a word. Seen on a real server, found by the diagnostics of 1.2.6. The passphrase of the server is now kept in that case, and it is said. If the timer runs and there is no passphrase anywhere, the weekly backup is turned off, and it is said.

## [1.2.6] - 2026-11-06

Reliability and finishing touches.

### Security
- **Home page of the seedbox**: `https://your-domain/` sent visitors to `/transmission/web/` before asking for the password (nginx answered a `return` before checking it), so anyone could see that Transmission was behind. The password is now asked first: `401` without it.

### Changed
- **Diagnostics** (`seedtunnel doctor`) check more:
  - every kernel network setting of the hardening (IPv4, and IPv6 if the server has it), not two of them; `seedtunnel apply` loads them again as soon as one differs (and only then);
  - the NAT rule of the VPN: there, for the network of the VPN, and made for the network interface the server uses now;
  - the firewall: its rules really refuse what is not allowed (`firewall status` too);
  - the weekly backup: its timer is running, its passphrase is there and readable by root only;
  - an update that did not finish (`/opt/seedtunnel.previous` left).
- **Dates in words**: « today », « yesterday », « 3 days ago » instead of « 0 day(s) ago ».
- **Changing the port of the VPN** says that every client is disconnected; if your SSH session goes through the VPN, it asks first (« no » by default).
- **Confirming the firewall**: the message says which new connection counts (from the Internet, always; through the VPN, only if this session goes through the VPN too).
- **Weekly backup**: a new passphrase says that the backups already made keep theirs.
- **Language**: the question is asked again until the answer is 1 or 2 (empty = back, from the menu); a saved file holding anything else asks it again too.

### Fixed
- **Services at boot**: the timers of the certificate, of the full disk protection and of the weekly backup, and the firewall loaded at boot, are now enabled at boot **and** running after `seedtunnel apply` (a timer turned off by hand, or a service enabled but stopped, stayed so). Nothing is done when they already are. An enabling at boot of the VPN that fails is now said.
- **Full disk protection**: if Transmission did not start again once there was room, the protection forgot it had stopped it. It now tries again at each check, writes it in the journal, and `doctor` says that Transmission does not start (not that the disk is full).
- **Free space that cannot be measured**: a failing `df` stopped `doctor` and the full disk protection with an « unexpected error ». « Unreadable » is now shown, and they go on.
- **Validation**: an IPv4 address with a leading zero (`010.0.0.1`) is refused; a list of DNS servers ending with a comma too; the public address of the VPN must be an IPv4 or IPv6 address or a domain name.
- **Update with git**: only `vX.Y.Z` tags are taken, and only if their code says that version.
- **Commands**: an unknown command, or arguments too many (`apply`, `update`, `doctor`, `restore FILE`, `language X`), are refused before anything is done.
- **`seedtunnel` shortcut**: a link pointing elsewhere (an older copy) is put right; a file of another program is left alone, and it is said.
- **One-time links**: the free space of `/run` (in memory) is checked before copying the file; the page of a link is no longer counted by the limit of one download.
- **VPN**: the NAT rules are checked before the clients are changed; a test interface left by a check cut short no longer stops the installation.
- **Language**: the saved choice is written aside, then renamed.
- **Translation check**: an empty translation, or a « % » that printf would misread (`100 %`), is now refused.

## [1.2.5] - 2026-11-06

Security and data, after a review of every file of 1.2.4.

### Changed
- **Every question of the menu can be left with an empty answer**: you go back, nothing is changed (« empty = back » is shown). « Add a client », for example, could not be left once started. A wrong answer (unknown client, invalid key or IP, wrong passphrase…) is now asked again instead of leaving the menu.

### Security
- **SFTP, keys only**: sshd could still accept a password through the « keyboard-interactive » login. It is now turned off, and it is checked (from the server, through the VPN and from the Internet) that sshd refuses passwords when asked, accepts keys and reads the keys of seedtunnel; otherwise the account is suspended.
- **SFTP account reactivated**: now checked (expiry date read back). On failure, the account stays suspended and the command to run by hand is given.
- **Restore**: an archive holding a link (other than those of Let's Encrypt) or a special file is refused: a link to `/etc/shadow` could have been written through. The settings files are read by bash: one holding anything but plain settings (`$(…)`, backticks, `;`…) is refused too, as it could run commands.
- **One-time links**: the token was written in clear in the log of nginx. It is now hidden (`/share/<token>/…`).

### Fixed
- **Removal of packages**: it is now tried first (`apt-get -s`), for the packages and for their dependencies. If it would take a package that seedtunnel did not install, nothing is removed and the packages concerned are named. The list of the packages installed by seedtunnel is no longer emptied when the installed packages cannot be read.
- **Backups**: if a setting changed while the archive was written (renewal of a certificate…), the archive could mix old and new settings. It is now made again, up to 3 times. `--output` replaced an existing file: it now refuses. The passphrase of the weekly backup is written aside, then renamed: a full disk can no longer leave it cut.
- **SFTP keys**: importing several keys added the valid ones before an invalid one: now all or nothing. Removing a key rewrote the file in place: it is now written aside, then renamed, and stays whole on failure.
- **Renaming the SFTP account**: if putting the old name of the group back failed too, nothing said so. The commands to run by hand are now given, and the account stays suspended.
- **Firewall**: turning it off now checks that the rules are really gone; otherwise it stops without deleting anything. If the automatic undo cannot be cancelled, the previous rules come back. The rules loaded at boot are only replaced once the new ones are loaded; if that fails, the next `seedtunnel apply` tries again. The firewall is noted as on before being enabled at boot, so that `apply` puts it right.
- **Removing the VPN**: the keys were deleted even if the tunnel could not be stopped. It now checks first that wg0 and its NAT rules are gone.
- **One-time links**: a link prepared halfway (full disk) was left behind: it is now deleted.
- **Update**: if the new version could not be put in place, the folder of seedtunnel was missing: the previous version now comes back at once. A `.previous` folder left by an interrupted update is no longer deleted (it may be the only working copy): the update stops and explains. If the previous version, once back, cannot apply its configuration either, it is now said. With git, if going back to the previous commit failed, the version that had just failed was applied again: it now stops with the git command to run. The README says how to put things back by hand after a power cut during an update.

## [1.2.4] - 2026-11-01

Confirming the firewall, after a review of 1.2.3.

### Fixed
- **The rule was not the one written**: 1.2.3 said a new login had to come « the same way » as your session. In fact (and on purpose), a login from the Internet always counts: it is the way the new rules can break. The rule, now written as it is: from the Internet, always; through the VPN, only if your session comes through the VPN; from the server itself, never.
- **A login from the server to its own public address** (`ssh admin@its-address`, run on the server) counted, although it never leaves the server. All the addresses of the server are now left out, not only 127.0.0.1 and ::1.
- **Any message starting with « Accepted publickey… »** counted, whatever program wrote it. Only those written by the OpenSSH programs count now (journald notes the real program that wrote each message). Tested on Debian 12 and 13 with a real SSH login, and with a fake message written by another program calling itself sshd.

## [1.2.3] - 2026-11-01

### Changed
- **Firewall**: since 1.2.2, confirming the new rules needed a new SSH connection from the Internet, so the VPN had to be turned off first. A new login now counts when it comes the same way as the session running seedtunnel: through the VPN if you are connected through it (the VPN is always allowed: you cannot be locked out that way), from the Internet otherwise. Logins from the server itself never count.

## [1.2.2] - 2026-11-01

Third audit, of 1.2.1: the remaining ways a step could fail halfway.

### Security
- **SFTP suspension**: if the account could not be suspended (account database locked…), the message still said it was. The suspension is now checked (expiry date read back, no process left), and a failure is said, with the command to run by hand.
- **SFTP restrictions**: they were only checked for a connection from the server itself, and 3 of the 8 were checked. All 8 are now checked (tunnels, TTY, X11, agent included), for a connection from the server, through the VPN and from the Internet: a `Match Address` block could treat them differently.
- **Firewall**: a new SSH login through the VPN (always allowed) counted as proof that SSH works with the new rules. Only a login from the Internet counts now.

### Fixed
- **Renaming the SFTP account**: if a step failed halfway (group, keys), the account kept its new name while seedtunnel kept the old one, and the next run would have created a second account. The steps already done are now undone: the account keeps its old name.
- **Restore**: when it stopped halfway, nothing said how to get back. It now says where the previous settings are kept and the command to go back to them.
- **Diagnostics**: when HTTPS could not be reached, the check of the certificate served said nothing. It now says that the certificate was not checked.
- **DNS of the VPN**: some invalid IPv6 addresses (`2001:::1`) were accepted.

## [1.2.1] - 2026-11-01

Second audit of 1.2.0: what could still go wrong without anything failing.

### Security
- **SFTP**: if sshd did not apply the restrictions of the SFTP account (chroot, SFTP only, no tunnel), for example because of a `Match` block placed before them, the account kept working without them, with a mere warning. It is now suspended (sessions closed) until they apply, and comes back by itself then.
- **Renaming the SFTP account**: between the rename and the new SSH rule, the account had a name that no rule covered. It is now suspended during the change.
- **Self-signed certificate**: the download links (which may carry a private key) only said to accept the warning of the browser. They now give the SHA-256 fingerprint of the certificate, to check before accepting it.
- **Files holding a secret**: a `--config` file readable by others was only warned about, and `SEEDBOX_PASSWORD_FILE` and `--passphrase-file` were not checked. All three are now refused unless readable by root only.
- **Firewall**: « yes » kept the new rules even if no new SSH connection had been tried. It now only counts once sshd has accepted a new login since the rules were applied; otherwise the question comes back, until the automatic undo.

### Fixed
- **Removal**: removing the seedbox or the VPN purged nginx, certbot, fail2ban… even if they were there before seedtunnel, then ran `apt autoremove`, which could take packages that have nothing to do with seedtunnel. Only the packages installed by seedtunnel (and the dependencies they brought) are now removed. On a server set up by an older version, what that version installed is still removed.
- **Transmission**: its settings were rewritten in place: a full disk at that moment left them half-written, and Transmission stayed stopped. They are now written aside, checked, then renamed; on failure the previous ones stay and Transmission starts again.
- **Transmission** started even when the disk of the data was not mounted, filling the system disk. It now waits for it (`RequiresMountsFor`).
- **Installation**: nginx listening on one of the ports 80/443 hid another program on the other one. Each port is now checked.
- **Full disk protection**: when the free space could not be measured, it did nothing, silently. It now says so (terminal and journal); Transmission is left running.
- **Diagnostics**: `seedtunnel doctor` now checks the Let's Encrypt certificate as a browser does (chain, name, dates), through the public IP: a valid file on the disk is not enough if nginx serves another one.

### Changed
- **Kill switch**: if the tunnel drops, a client goes out without it, with its real address. The help of a new client, the download page of its configuration and the README now say how to prevent it (Windows, Android, qBittorrent).

## [1.2.0] - 2026-10-31

Fixes from an independent audit of 1.1.2: what happens when a step fails
halfway.

### Fixed
- **Removing the seedbox**: the SSH restrictions of the SFTP account (chroot, no tunnel) were removed before the account itself; if the account could not be deleted (open SFTP session), it stayed without them. The account now goes first (its sessions are closed), and if it cannot be deleted, nothing is removed.
- **Firewall, nginx, SSH**: a configuration refused once (failed reload) was not applied at the next run, the file being already up to date. It now keeps a mark until the service really took it.
- **Firewall undo**: a failed return to the previous rules was announced as done, and the automatic undo was cancelled. It is now reported, and the automatic undo stays scheduled.
- **Backups**: the temporary file had a predictable name, and an existing link at that name was followed. It is now created by `mktemp`, in a folder that must belong to root.
- **One-time links**: a link was shown even if its watcher had not started, and stayed downloadable if the watcher died. No watcher now means no link, and systemd deletes the link whenever the watcher stops.
- **Restore**: the decrypted archive could stay on the disk after a failure. It is now deleted whatever happens.
- **Update**: the previous version was deleted before the new one had applied the configuration. It is now kept until then, and comes back if the new one fails.
- **Full disk**: after a reboot, Transmission started before the first check. It now checks the free space before starting.
- **Diagnostics**: a weekly backup that never worked looked like a recent one; `seedtunnel doctor` now warns when no automatic backup came within 8 days of turning it on, or when the last one failed. A download of a backup that was cut short counted as a backup on your computer: the page now gives the expected size, and doctor only says the download started.
- **Validation**: IPv4 addresses out of range (`256.1.2.3`), ports with a leading zero and invalid DNS lists are refused.
- The help and the example still said the Let's Encrypt test servers have « no limit »: their limits are higher, not absent.

### Changed
- README: the RPC of Transmission (not its BitTorrent port) only listens locally; the VPN clients are trusted by the firewall.

## [1.1.2] - 2026-10-31

### Changed
- French messages and README: the English words French people actually use in computing, instead of literal translations: « passphrase » (was « phrase de passe »), « hash » for the passwords and « checksum » for the archives (was « empreinte »). « Empreinte » stays for the SSH key of the server, as in WinSCP.

## [1.1.1] - 2026-10-31

### Fixed
- **Firewall**: refusing a change, or not confirming it within 2 minutes, removed all the seedtunnel rules instead of putting the previous ones back, and the refused rules were loaded at the next boot. The new rules are now tried from their own file: undoing puts back the rules in use before (or no rules, the first time), and the rules loaded at boot only change once confirmed.
- **VPN**: after a change refused by WireGuard, running again reported success without applying it, since the files were already up to date. A revoked client could stay connected until the VPN restarted. The running VPN is now put in line with its files at every run.
- **One-time links**: two requests one right after the other (on the same connection) could both get the file, and a HEAD request used the link up without downloading anything. nginx now serves the file of a link only once, and refuses HEAD without using the link up.
- **Backups**: a backup that failed left a truncated file, which then counted as the latest backup (`backup share`, diagnostics). A backup is now written to a temporary file, checked by decrypting it, and only then renamed.
- **Automatic tests**: the checks of the SSH and HTTPS ports from the outside could not fail; now they can. The open port of a VPN client is now tested from the outside, through the tunnel.

### Changed
- README: more exact wording on the passphrase of the weekly backup (saved on the server, readable by root only), the disk check (every 5 minutes), the limits of the Let's Encrypt test servers and the undo of the firewall.

## [1.1.0] - 2026-10-31

### Added
- **`seedtunnel seedbox sftp-key new`**: creates an SSH key for WinSCP / FileZilla and gives a one-time link to it as a .ppk file, for SFTP without a password. Its public part is added to the allowed keys; no copy of the private key stays on the server. Also offered in the « SFTP connection » screen and in the SSH keys menu.

### Changed
- SSH keys menu: « Create a key for WinSCP / FileZilla » is choice 2; removing a key and the SFTP password moved to 3 and 4.

## [1.0.1] - 2026-10-31

### Fixed
- Seedbox menu, « Domain name and HTTPS certificate »: once inside, there was no way back. An empty answer (or Q when the name does not point to the server) now goes back without changing anything.
- Replacing a valid Let's Encrypt certificate is now explained and confirmed before anything is done (Let's Encrypt issues at most 5 certificates a week for the same name). Typing the same name again keeps the certificate, without a new request.

## [1.0.0] - 2026-10-31

**seedtunnel is the new name of finalcut** (versions 1.0.0 to 2.2.2 below),
rewritten for an English-speaking audience, with French still available.

### Added
- **Messages in English and French**, chosen for each server: question at the first start of the menu, `seedtunnel language en|fr`, `L` in the menu, `LANGUAGE` key of the configuration file, or `SEEDTUNNEL_LANG` in the environment.
- **Weekly backup**: `seedtunnel backup auto on` makes an encrypted backup every week and keeps the last 4. `seedtunnel backup auto off|status`.
- **`seedtunnel backup share`**: one-time link to download the latest backup onto your computer.
- **The backup includes the state of Transmission**: list of torrents, progress and settings, put back by `seedtunnel restore`.
- **`seedtunnel doctor` watches the backups**: warning when the weekly backup is off, when the last automatic backup is more than 8 days old, and when no backup was downloaded for 30 days.
- **Full disk protection**: every 5 minutes, under 3 GB free in the data folder, Transmission is stopped cleanly; it starts again by itself above 5 GB. The menu and `seedtunnel doctor` show it.
- **Unit tests** (`make unit`) and a translation check (`make i18n`), run at every push.

### Changed
- New name everywhere: the `seedtunnel` command, `/opt/seedtunnel`, `/etc/seedtunnel`, `/var/log/seedtunnel.log`. Backups go to `/var/backups/seedtunnel`. Download links are served under `/share/`.
- Full words instead of abbreviations in the configuration file:

  | finalcut | seedtunnel |
  |---|---|
  | `VPN_ENDPOINT` | `VPN_PUBLIC_ADDRESS` |
  | `SB_USER` | `SEEDBOX_USER` |
  | `SB_PASSWORD`, `SB_PASSWORD_FILE` | `SEEDBOX_PASSWORD`, `SEEDBOX_PASSWORD_FILE` |
  | `SB_DOMAIN` | `SEEDBOX_DOMAIN` |
  | `SB_DATA` | `SEEDBOX_DATA_DIR` |
  | `SB_LETSENCRYPT` | `SEEDBOX_LETSENCRYPT` |
  | `SB_ACME` | `SEEDBOX_LETSENCRYPT_SERVER` |
  | `SB_SSH_KEYS_FILE` | `SEEDBOX_SSH_KEYS_FILE` |
  | `SB_SFTP_PASSWORD` | `SEEDBOX_SFTP_PASSWORD` |

- `seedtunnel backup` and `seedtunnel doctor` no longer wait for a menu left open in another window. When the script is already running, the message says which process, since when, and how to stop it.
- Removing both the VPN and the seedbox also turns the weekly backup off (the existing backups are kept).

### Fixed
- A VPN change refused by WireGuard showed « ok »: only the result of the last step was checked. Every step is now checked.
- A configuration file could be replaced by a half-written one if its generation failed (full disk). The previous version is now kept.
- A one-time link could be used more than once, with another form of the address (`?x` at the end) or with partial downloads. The file is now deleted as soon as it is opened, and served whole to one connection at a time.

### Moving from finalcut
There is no automatic migration. Remove finalcut (`finalcut seedbox uninstall`, `finalcut vpn uninstall`, `finalcut firewall disable`, then delete `/opt/finalcut`, `/etc/finalcut` and `/usr/local/bin/finalcut`), install seedtunnel, then import the new configurations of the VPN clients.

## finalcut (former name)

### [2.2.2] - 2026-10-31
- `finalcut seedbox sftp-config` is made for WinSCP first: the address to paste holds the fingerprint of the server, which WinSCP checks by itself. The FileZilla file is only created on request.

### [2.2.1] - 2026-10-31
- Main menu: the disk space also shows the total size, in color, and whether the partition holds both the system and the downloads.

### [2.2.0] - 2026-10-31
- Added `finalcut vpn share NAME` (one-time download link), `finalcut seedbox sftp-config`, the state of the server at the top of the menu, `finalcut apply`, and hardened kernel network settings.
- Fixed: fail2ban only banned attackers of SSH from port 22; `finalcut doctor` checks that the SSH port is open in the firewall.

### [2.1.3] - 2026-10-31
- The repository is renamed `finalcutgit411/finalcut`.

### [2.1.2] - 2026-10-31
- Fixed: ports 80/443 opened too late when the firewall was on before the seedbox (Let's Encrypt could not validate). The `finalcut` command goes into `/usr/local/bin`.

### [2.1.1] - 2026-10-31
- Fixed: `sysctl: command not found` after a `su` without a dash. An interrupted VPN installation is resumed.

### [2.1.0] - 2026-10-31
- Commands without the menu, configuration file, idempotent installation, Let's Encrypt test servers, SSH keys for SFTP, nftables firewall with automatic undo, Transmission locked down by systemd, `finalcut doctor`, encrypted backup and restore, `finalcut update` with a SHA-256 check, automatic tests and releases on GitHub.
- Seedbox passwords kept as hashes only.

### [2.0.0] - 2026-10-31
- Full rewrite for Debian 12/13: WireGuard instead of OpenVPN, SFTP instead of vsftpd, nftables instead of iptables, certbot from Debian, detailed log.

### [1.0.0] - 2016
- First version: Debian 7/8, OpenVPN + sslh, Transmission, vsftpd, Let's Encrypt (`certbot-auto`).
