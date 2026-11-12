# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.

## [0.9.0] - 2026-11-12

First published version. SeedTunnel is meant for everyday use from version 1.0.0 on; until then, a 0.x version may still change how things look or work.

### What it does
- **WireGuard VPN**: up to 253 named clients, each with its QR code (it fits in a window of 80 columns) or a one-time download link (with the seedbox), its own open port (TCP and UDP) and no IPv6 leak. DNS of the clients to choose: Quad9 (default), Cloudflare, DNS4EU, AdGuard or your own addresses.
- **Seedbox**: Transmission 3 or 4 behind nginx in HTTPS, with a Let's Encrypt certificate renewed by itself (self-signed without a domain name), and a web interface in the colors of SeedTunnel. Files in SFTP, locked in the folder of the seedbox, with a password or SSH keys (a key ready for WinSCP and FileZilla). Transmission stopped cleanly before the disk is full.
- **Protection**: nftables firewall applied on trial (it undoes itself after 2 minutes unless a new SSH login proves you still have access), fail2ban, passwords kept as hashes, automatic security updates, hardened network settings of the kernel.
- **Maintenance**: diagnostics that give the command fixing each problem, and an anonymized report to share; encrypted backups, every week (the last 4 kept), restored on the same server or on a new one, from one system to another; verified updates, with a way back to the previous version.
- **Systems**: Debian 12 and 13, Ubuntu Server 24.04 and 26.04. English and French.
