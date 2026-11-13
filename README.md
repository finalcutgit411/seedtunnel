<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/banner-en-dark.svg">
    <img src="docs/banner-en-light.svg" alt="SeedTunnel. Your own VPN and seedbox, on your own server. One command. No Docker. Nothing hidden." width="640">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/finalcutgit411/seedtunnel/actions/workflows/ci.yml"><img src="https://github.com/finalcutgit411/seedtunnel/actions/workflows/ci.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/finalcutgit411/seedtunnel/releases/latest"><img src="https://img.shields.io/github/v/release/finalcutgit411/seedtunnel?label=release" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/finalcutgit411/seedtunnel" alt="License: GPL-3.0"></a>
</p>

<p align="center">By FinalCut · <a href="README.fr.md">Français</a></p>

<p align="center"><img src="docs/screens/en-home.png" alt="The home screen of SeedTunnel: the VPN, the seedbox, the firewall, the disk and the backups at a glance" width="760"></p>

<table>
  <tr>
    <td width="33%" valign="top"><b>Simple</b><br>One menu in your terminal. Add a phone to the VPN and scan its QR code, connect WinSCP, make a backup: a few keys each time.</td>
    <td width="33%" valign="top"><b>Safe</b><br>Firewall, HTTPS, fail2ban, encrypted backups, SFTP locked in its folder. Nothing is open that you did not ask for.</td>
    <td width="33%" valign="top"><b>Light</b><br>Plain Bash and the packages of your distribution. No Docker, no database. 1 GB of RAM is enough.</td>
  </tr>
</table>

## Quick start

Rent a small VPS with Debian 12/13 or Ubuntu Server 24.04/26.04, connect to it with SSH, and paste this as root (or after `sudo -i`):

```bash
apt update && apt full-upgrade -y
V=1.0.2
cd "$(mktemp -d)"
curl -fLO https://github.com/finalcutgit411/seedtunnel/releases/download/v$V/seedtunnel-$V.tar.gz \
  && curl -fLO https://github.com/finalcutgit411/seedtunnel/releases/download/v$V/SHA256SUMS \
  && sha256sum -c SHA256SUMS \
  && tar -xzf seedtunnel-$V.tar.gz \
  && mv seedtunnel-$V /opt/seedtunnel \
  && /opt/seedtunnel/seedtunnel.sh
```

On Ubuntu, turn ufw off first (`ufw disable`): SeedTunnel brings its own firewall.

The menu opens at the end and asks only what it needs. Later, type `seedtunnel` to open it again.

## What you get

| | |
|---|---|
| **WireGuard VPN** | A QR code for each phone, a one-time download link for each computer, an open port for each client for your torrents, no IPv6 leak. |
| **Seedbox** | Transmission in your browser, in HTTPS, with a Let's Encrypt certificate that renews itself. Your files over SFTP, with profiles ready to import into WinSCP and FileZilla, and an SSH key made for you if you have none. |
| **Protection** | nftables firewall, fail2ban, passwords kept only as hashes, automatic security updates, Transmission stopped cleanly before the disk is full. |
| **Upkeep** | A full diagnostic, encrypted backups every week, verified updates with a way back, and an anonymized report to share when you ask for help. |

<p align="center">
  <img src="docs/screens/en-add.png" alt="A new VPN client: its address, its open port, its DNS and its file" width="49%">
  <img src="docs/screens/en-client.png" alt="How to install the tunnel on a phone or a computer, the port for torrents, the kill switch" width="49%">
</p>
<p align="center">
  <img src="docs/screens/en-sftp.png" alt="SFTP connection: the settings, the WinSCP and FileZilla profiles, the SSH keys explained" width="49%">
  <img src="docs/screens/web.png" alt="The web interface of Transmission in the colors of SeedTunnel" width="49%">
</p>

## Is it for you?

**Yes**, if you rent a KVM VPS or a dedicated server, even a small one, and you want:

- your own seedbox, without spending a weekend on it;
- a VPN for your phones and computers (public Wi-Fi, travel, family), with or without the seedbox;
- to know exactly what runs as root on your server.

**No**, if you are looking for Sonarr, Radarr, Plex and the like, a seedbox with several accounts, or everything in Docker. SeedTunnel stays small on purpose: one Transmission, one SFTP account, one VPN. For Sonarr, Radarr or Plex, have a look at [swizzin](https://swizzin.ltd/) instead.

## Why you can trust it

- **You can read it.** Plain Bash from top to bottom: start with `seedtunnel.sh`, then `lib/`. The archive is checked against its SHA-256 fingerprint before anything runs.
- **You can fix it.** `seedtunnel doctor` checks the whole server and gives, for each problem, the command that fixes it. `seedtunnel update back` goes back to the previous version.
- **You cannot lock yourself out.** The firewall starts as a trial: if you cannot open a new SSH connection within 2 minutes, it removes itself.
- **You can move.** Encrypted backups restore on the same server or on a new one, even from Ubuntu to Debian.
- **It is tested.** Every change goes through more than 250 unit tests and a full installation on Debian 12 and 13, Ubuntu Server 24.04 and 26.04.

<p align="center"><img src="docs/screens/en-diagnostic.png" alt="A full diagnostic: everything in order" width="560"></p>

## Day to day

Everything is in the menu (`seedtunnel`). The same things also exist as commands, as root or with `sudo`:

| Command | What it does |
|---|---|
| `seedtunnel vpn add phone --qr` | Adds a VPN client and shows its QR code |
| `seedtunnel vpn share laptop` | One-time download link for the file of a client |
| `seedtunnel seedbox sftp-config winscp` | One-time link to a WinSCP profile (or `filezilla`) |
| `seedtunnel doctor` | Checks everything, with the fix for each problem |
| `seedtunnel doctor --link` | The same, with an anonymized report to share |
| `seedtunnel backup` / `backup share` | Encrypted backup / one-time download link |
| `seedtunnel restore [FILE]` | Restores a backup, on this server or on a new one |
| `seedtunnel update` / `update back` | Verified update / back to the previous version |

<details>
<summary><b>What it changes on your server</b></summary>

- **Packages**: only those of your distribution (WireGuard, Transmission, nginx, certbot, fail2ban, nftables and a few tools). SeedTunnel notes the ones it installed and removes them when it is removed.
- **One account**: the SFTP account of the seedbox, without shell access.
- **Its files**: the code in `/opt/seedtunnel` (the `seedtunnel` command in `/usr/local/bin`), the settings in `/etc/seedtunnel` (root only), the log in `/var/log/seedtunnel.log` (archived every month), the downloads in `/srv/seedbox`, the backups in `/var/backups/seedtunnel`.
- **System settings**, in files named after it: WireGuard, Transmission, nginx (its site, the default site turned off), fail2ban, SSH (the SFTP account locked in), AppArmor (folder of Transmission), network settings of the kernel, systemd services and timers (firewall, weekly backup, full disk protection), log archiving, automatic security updates.
- **Removal**: takes away what SeedTunnel installed. Your backups stay, and so do your downloads, unless you ask to delete them.

</details>

<details>
<summary><b>Known limits</b></summary>

- KVM virtual servers and dedicated servers only, not OpenVZ or LXC containers.
- On Ubuntu, ufw must be turned off (see [Quick start](#quick-start)).
- Docker on the same server can block the traffic of the VPN. `seedtunnel doctor` detects it and says what to change; SeedTunnel itself never touches the rules of Docker.

</details>

## Need help?

Open an [issue on GitHub](https://github.com/finalcutgit411/seedtunnel/issues) and attach the report of `seedtunnel doctor --link`: your IP address, your domain and your account names are replaced in it.

## Documentation

- [Guide](docs/guide.md): every menu and every command
- [Security](docs/security.md): how the server is protected
- [Development](docs/development.md): tests and translations
- [Changelog](CHANGELOG.md)

## Credits

**FinalCut**: author of SeedTunnel, created in 2016 and rewritten in 2026.

## License

[GPL-3.0-or-later](LICENSE): you can use, study, change and share SeedTunnel freely. A version you share, changed or not, stays under the same license, with its source code.

Copyright © 2016-2026 FinalCut.
