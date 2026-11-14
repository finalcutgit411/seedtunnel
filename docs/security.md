# SeedTunnel — Security

*[Version française](securite.fr.md)* · [← Back to the README](../README.md)

## What SeedTunnel protects

- The control interface of Transmission (RPC) only listens on `127.0.0.1`: it is reached through nginx, and the password is checked twice, by nginx then by Transmission. Only its BitTorrent port (60000) is open to peers.
- Transmission is **locked down by systemd** (`ProtectSystem=strict`…): it can only write in its own folders, and can run nothing from the folders where it or the SFTP user writes. It runs no program at the end of a download (the web interface could turn one on: `seedtunnel apply` turns it off again, `seedtunnel doctor` says it). Its settings, which hold the hash of the password, can only be read by its own account.
- The **VPN clients cannot reach each other**, and nothing from outside the tunnel reaches them, except the answers to their own connections and their open port (60001 and up). This holds with the firewall on or off.
- **Docker on the same server keeps its protection**: so that the VPN clients have the Internet, SeedTunnel only adds two rules to `DOCKER-USER`, limited to the network of the VPN (10.8.0.0/24). Nothing opens the way to the containers, and the settings of Docker are not changed.
- Passwords are **never written in plain text**, nor passed as the argument of a command: only their hashes are kept. One exception: the passphrase of the weekly backup, if you turn it on, saved readable by root only so that the backup runs by itself. Every backup holds it too, so that a restore keeps the weekly backup running: whoever can open one backup can open the weekly ones. Give the passphrase of any backup the same care.
- The SFTP user is locked in the data folder: no shell, no tunnel. If sshd does not apply all these restrictions to it, from the server, through the VPN and from the Internet (a `Match` block placed before them in `sshd_config`, for example), the account is suspended rather than left without them. In « keys only » mode, it is also checked that sshd refuses passwords (`keyboard-interactive` included).
- Files that may hold a secret (`--config`, `SEEDBOX_PASSWORD_FILE`, `--passphrase-file`) are refused if anyone other than root can read them.
- With a self-signed certificate, each download link comes with its SHA-256 fingerprint, to check before accepting the warning of the browser.
- fail2ban bans attackers of SSH from **every TCP port**, whatever the port of SSH. The VPN (UDP) stays open to them, but it needs a key: banned by mistake, you come back through it ([guide](guide.md#banned-from-ssh-come-back-through-the-vpn)).
- Hardened kernel network settings (`/etc/sysctl.d/90-seedtunnel-network.conf`): ICMP redirects ignored, source routing refused.
- The SSH configuration is checked (`sshd -t`) before it is reloaded. On error, the previous version is put back.
- TLS 1.2/1.3 only. HSTS is only turned on with a real certificate.
- Automatic security updates (`unattended-upgrades`).
- `/etc/seedtunnel` and the backups are readable by root only, and so are the settings a restore replaced (`/etc/seedtunnel.before-restore-…`, old keys and passphrase included). `seedtunnel doctor` points them out until they are deleted: Backup / restore → « My backups », or `seedtunnel restore clean`.
- A backup made by someone else cannot run anything when restored: no executable file, only the settings of SeedTunnel with values it would accept, valid names of VPN clients, every file owned by root, and from Let's Encrypt only the certificate of SeedTunnel, renewed with no command other than reloading nginx.
- root never writes where the account of Transmission (or the SFTP user) could lead it with a link: the settings of Transmission and the torrents put back are written by its own account.
- The token of a download link, its password, is never in the argument of a command (`ps` and `systemctl status` show those to every account), nor is the hash of the seedbox password.

## What SeedTunnel does not promise

- **The VPN does not make you anonymous.** It encrypts everything between your device and the server; after that, websites see the address of the server, and the provider sees the traffic like that of any server.
- **A server is never invulnerable.** SeedTunnel runs as root: the security of your SSH accounts stays yours (a strong password, or better, a key).
- **A backup is only worth something if it is elsewhere.** Keep a copy and the passphrase off the server: without the passphrase, it does not open.
- **Other software** installed by hand on the server needs its own care.
