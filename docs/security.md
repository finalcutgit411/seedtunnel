# SeedTunnel — Security

*[Version française](securite.fr.md)* · [← Back to the README](../README.md)

- The control interface of Transmission (RPC) only listens on `127.0.0.1`: it is reached through nginx, and the password is checked twice, by nginx then by Transmission. Only its BitTorrent port (60000) is open to the peers.
- Transmission is **locked down by systemd** (`ProtectSystem=strict`…): it can only write to its own folders.
- Passwords are **never written in clear**, nor given as an argument to a command. Only their hashes are kept. The one exception is the passphrase of the weekly backup, if you turn it on: it is saved readable by root only, so that the backup can run alone.
- The SFTP user is locked inside the data folder: no shell, no tunnel. If sshd does not apply all these restrictions to it, from the server, through the VPN and from the Internet (a `Match` block before them in `sshd_config`, for example), the account is suspended rather than left without them. In « keys only » mode, it is also checked that sshd refuses passwords (keyboard-interactive login included) and reads the keys of seedtunnel.
- The files that may hold a secret (`--config`, `SEEDBOX_PASSWORD_FILE`, `--passphrase-file`) are refused if anyone but root can read them.
- With a self-signed certificate, every download link comes with its SHA-256 fingerprint, to check before accepting the warning of the browser.
- fail2ban bans attackers of SSH from **every TCP port**, whatever the port of SSH. The VPN (UDP) stays open to them, but needs a key: banned by mistake, you come back through it ([guide](guide.md#banned-from-ssh-come-back-through-the-vpn)).
- Hardened kernel network settings (`/etc/sysctl.d/90-seedtunnel-network.conf`): ICMP redirects ignored, source routing refused.
- The SSH configuration is checked (`sshd -t`) before being reloaded. On error, the previous version is put back.
- TLS 1.2/1.3 only. HSTS is only turned on with a real certificate.
- Automatic security updates (`unattended-upgrades`).
- `/etc/seedtunnel` and the backups are readable by root only. So are the settings a restore replaced (`/etc/seedtunnel.before-restore-…`, old keys and passphrase included): `seedtunnel doctor` points them out until they are deleted.
- A backup made by someone else cannot run anything when it is restored: no file that could be run, only the settings of seedtunnel with values it would accept, every file to root, and from Let's Encrypt only the certificate of seedtunnel, renewed with no other command than the reload of nginx ([guide](guide.md)).
- Root never writes where the account of Transmission (or the SFTP user) could lead it with a link: the settings of Transmission and the torrents put back are written by its own account.
- The token of a download link, its password, is in no argument of a command (`ps`, `systemctl status` show those to every account), and neither is the hash of the password of the seedbox.
