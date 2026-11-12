<h1 align="center">SeedTunnel</h1>

<p align="center"><b>WireGuard VPN and a secure seedbox on your own server.<br>Bash you can read before you give it root.</b></p>

<p align="center">
  <a href="https://github.com/finalcutgit411/seedtunnel/actions/workflows/ci.yml"><img src="https://github.com/finalcutgit411/seedtunnel/actions/workflows/ci.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/finalcutgit411/seedtunnel/releases/latest"><img src="https://img.shields.io/github/v/release/finalcutgit411/seedtunnel?label=release" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/finalcutgit411/seedtunnel" alt="License: MIT"></a>
</p>

<p align="center">By FinalCut · <a href="README.fr.md">Français</a></p>

<p align="center"><img src="docs/seedtunnel-accueil.png" alt="The home screen of SeedTunnel: state of the VPN, the seedbox, the firewall, the disk and the backups" width="760"></p>

<p align="center"><sub>Screens in French; every menu and message also exists in English.</sub></p>

## Why trust it

Every seedbox script says it is simple. SeedTunnel aims at something rarer: a script you can check before you run it, fix when something breaks, and undo.

**You can check it.**

- Bash readable from top to bottom: start with `seedtunnel.sh`, then `lib/`. No Docker, no database, only packages of your distribution.
- The archive is checked against its SHA-256 fingerprint before anything runs.
- This page lists what SeedTunnel changes on your server, and removing it takes that away.

**You can fix it.**

- `seedtunnel doctor` goes through the whole server and gives, for each problem, the command that fixes it.
- `seedtunnel update back` goes back to the previous version.
- The firewall is turned on as a trial: open a new SSH connection from your computer within 2 minutes, to prove you still have access. Otherwise it removes itself.
- Encrypted backups restore on the same server or on a new one, even from Ubuntu to Debian or the other way round.

**It follows current systems.**

- Debian 12 and 13, Ubuntu Server 24.04 and 26.04.
- Every change goes through more than 250 unit tests and a full installation on these four systems.

## Is it for you?

**Yes**, if you rent a KVM VPS or a dedicated server, even a small one (1 GB of RAM is enough), and you want:

- your own seedbox, without spending a weekend on it;
- a VPN for your phones and computers (public Wi-Fi, family), with or without the seedbox;
- to know exactly what runs as root on your server.

**No**, if you are looking for Sonarr, Radarr, Plex and the like, a seedbox with several accounts, or everything in Docker. SeedTunnel stays small, on purpose: one Transmission, one SFTP account, one VPN. For Sonarr, Radarr or Plex, have a look at [swizzin](https://swizzin.ltd/) instead.

## What you get

| | |
|---|---|
| **WireGuard VPN** | A QR code for each phone, a one-time download link for each computer (with the seedbox), an open port for each client, no IPv6 leak. |
| **Seedbox** | Transmission behind nginx in HTTPS, with a Let's Encrypt certificate renewed by itself (self-signed without a domain name). Files over SFTP, locked in the folder of the seedbox, with a password or an SSH key, and a key ready for WinSCP and FileZilla. |
| **Protection** | nftables firewall, fail2ban, passwords kept as hashes, automatic security updates, Transmission stopped cleanly before the disk is full. |
| **Upkeep** | Full diagnostics, encrypted backups every week, verified updates with a way back, and an anonymized report to share when you ask for help. |

<p align="center">
  <img src="docs/seedtunnel-vpn.png" alt="The VPN menu" width="49%">
  <img src="docs/seedtunnel-clients.png" alt="The VPN clients: address, open port, traffic and last connection" width="49%">
</p>
<p align="center">
  <img src="docs/seedtunnel-seedbox.png" alt="The seedbox menu, with the state of its services" width="49%">
  <img src="docs/seedtunnel-web.png" alt="The web interface of Transmission in the colors of SeedTunnel" width="49%">
</p>

## Installation

On a freshly installed Debian 12/13 or Ubuntu Server 24.04/26.04, as root (or after `sudo -i`):

```bash
apt update && apt full-upgrade -y
V=0.9.0
cd "$(mktemp -d)"
curl -fLO https://github.com/finalcutgit411/seedtunnel/releases/download/v$V/seedtunnel-$V.tar.gz \
  && curl -fLO https://github.com/finalcutgit411/seedtunnel/releases/download/v$V/SHA256SUMS \
  && sha256sum -c SHA256SUMS \
  && tar -xzf seedtunnel-$V.tar.gz \
  && mv seedtunnel-$V /opt/seedtunnel \
  && /opt/seedtunnel/seedtunnel.sh
```

On Ubuntu, turn ufw off first (`ufw disable`): SeedTunnel brings its own firewall.

The menu opens at the end. Later, `seedtunnel` opens it again.

## Day to day

As root, or with `sudo`:

| Command | What it does |
|---|---|
| `seedtunnel` | Opens the menu |
| `seedtunnel vpn add phone --qr` | Adds a VPN client and shows its QR code |
| `seedtunnel vpn share laptop` | Makes a one-time download link for the file of a client (with the seedbox) |
| `seedtunnel doctor` | Checks everything, with the fix for each problem |
| `seedtunnel doctor --link` | The same, with an anonymized report to share |
| `seedtunnel backup` / `backup share` | Encrypted backup / one-time download link |
| `seedtunnel restore [FILE]` | Restores a backup, on this server or on a new one (without a file: the list of those found) |
| `seedtunnel update` / `update back` | Verified update / back to the previous version |

<p align="center"><img src="docs/seedtunnel-diagnostic.png" alt="A full diagnostic, everything in order" width="520"></p>

## What it changes on your server

- **Packages**: only those of your distribution (WireGuard, Transmission, nginx, certbot, fail2ban, nftables and a few tools). SeedTunnel notes the ones it installed and removes them when it is removed.
- **One account**: the SFTP account of the seedbox, without shell access.
- **Its files**: the code in `/opt/seedtunnel` (the `seedtunnel` command in `/usr/local/bin`), the settings in `/etc/seedtunnel` (root only), the log in `/var/log/seedtunnel.log` (archived every month), the downloads in `/srv/seedbox`, the backups in `/var/backups/seedtunnel`.
- **System settings**, in files named after it: WireGuard, Transmission, nginx (its site, the default site turned off), fail2ban, SSH (the SFTP account locked in), AppArmor (folder of Transmission), network settings of the kernel, systemd services and timers (firewall, weekly backup, full disk protection), log archiving, automatic security updates.
- **Removal**: takes away what SeedTunnel installed. Your backups stay, and so do your downloads, unless you ask to delete them.

## Known limits

- KVM virtual servers and dedicated servers only, not OpenVZ or LXC containers.
- On Ubuntu, ufw must be turned off (see [Installation](#installation)).
- Docker on the same server can block the traffic of the VPN. `seedtunnel doctor` detects it and says what to change; SeedTunnel itself never touches the rules of Docker.

## Need help?

Open an [issue on GitHub](https://github.com/finalcutgit411/seedtunnel/issues) and attach the report of `seedtunnel doctor --link`: your IP address, your domain and your account names are replaced in it.

## Documentation

- [Guide](docs/guide.md): every menu and every command, known limits
- [Security](docs/security.md): how the server is protected
- [Development](docs/development.md): tests and translations
- [Changelog](CHANGELOG.md)

## Credits

**FinalCut**: author of SeedTunnel, created in 2016 and rewritten in 2026.

## License

[MIT](LICENSE).
