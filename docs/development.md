# SeedTunnel — Development

*[Version française](developpement.fr.md)* · [← Back to the README](../README.md)

### Files

| File | Role |
|---|---|
| `seedtunnel.sh` | entry point: options, commands |
| `lib/common.sh` | output, input, log, configuration file, apt |
| `lib/i18n.sh` | translations |
| `lib/ui.sh` | display of the menus: header, blocks, menus, tables, frames (widths in characters) |
| `lib/menu.sh` | home screen and main menu |
| `lib/vpn.sh` | WireGuard |
| `lib/seedbox.sh` | Transmission, nginx, Let's Encrypt, SFTP, fail2ban |
| `lib/firewall.sh` | nftables firewall |
| `lib/share.sh` | one-time download links |
| `lib/diskguard.sh` | full disk protection |
| `lib/backup.sh` | backups and restore |
| `lib/update.sh` | update, applying the configuration again |
| `lib/doctor.sh` | diagnostics |
| `lang/` | French messages (`fr.txt`) and long texts (`en.sh`, `fr.sh`) |
| `tests/` | unit tests, translation check, test image (Debian or Ubuntu), integration tests |
| `tools/preview.sh` | the screens of the menus with example data |
| `docs/` | this documentation and the screens of the README (left out of the release archives) |

Every module follows the same principle:
1. read the wanted state in `/etc/seedtunnel`;
2. generate the configuration files;
3. only replace the ones that changed (`write_if_changed`);
4. only restart the services concerned.

`seedtunnel apply` runs these steps again for everything installed. `seedtunnel update` runs it after every update.

### Translations

Messages are written in English, right in the code, as `printf` formats:

```bash
ok 'Client "%s" created.' "$name"
```

In French, each format is looked up in `lang/fr.txt`, a plain text file where every English line (`en: …`) is followed by its translation (`fr: …`). A missing translation simply shows the English text. Longer texts (help, summaries) are functions in `lang/en.sh` and `lang/fr.sh`.

`make i18n` checks that every message has its translation, with the same `%s`; `python3 tests/i18n_check.py --missing` prints the missing ones, ready to fill in.

### Automatic tests

At every push to GitHub, `.github/workflows/ci.yml`:

1. analyzes the code with **shellcheck**, checks the formatting with **shfmt** and the translations, then runs the **unit tests** (`tests/unit.sh`: bugs found in the past, so that they never come back);
2. starts a fresh Debian 12, Debian 13, Ubuntu 24.04 and Ubuntu 26.04 (containers with systemd), then runs `tests/integration.sh`, which:
   - checks on Ubuntu that nothing is installed while ufw is on;
   - really installs the VPN and the seedbox, and checks the **idempotence**;
   - opens a **real WireGuard tunnel**;
   - connects over **SFTP** with a password then with a key, and checks the lock-down;
   - tests the web interface, adds a **torrent** through the `watch/` folder;
   - checks that a **download link** only works once, even with another form of the address;
   - checks that fail2ban bans from every port, and the **full disk protection**;
   - tests the **firewall from the outside**;
   - makes **backups**, including weekly ones, downloads one, removes everything, **restores**, and checks that the old VPN client connects again and the torrents are back.

Locally: `make check` (needs `shellcheck`, `shfmt`, `python3`, `inotify-tools` and `qrencode`), and `make fmt` to format the code.

### Publishing a version

1. Update `APP_VERSION` in `lib/common.sh`, for example `1.1.0`.
2. Add a `## [1.1.0]` section to `CHANGELOG.md`.
3. Change `V=` in the installation block of `README.md` and `README.fr.md`.
4. Push to `master`.

`.github/workflows/release.yml` sees that a new version is not published yet. It runs all the tests again, then creates the tag `v1.1.0` and publishes on GitHub the archive, `SHA256SUMS` and the attestation of the archive. That is where `seedtunnel update` looks for new versions. Pushing a `v1.1.0` tag yourself works too. Development versions (with a dash, such as `1.1.0-dev`) are never published.

The repository used by `seedtunnel update` is set by `APP_REPO` in `lib/common.sh`. If you rename the repository or make a copy (fork), change it, as well as the links of the README and of these pages.
