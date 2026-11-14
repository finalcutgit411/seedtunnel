# SeedTunnel — Development

*[Version française](developpement.fr.md)* · [← Back to the README](../README.md)

## Layout

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
| `web/` | web pages (« Access denied » and « Nothing here » in English only; link used or expired and Transmission not responding, one file per language: `x.html` in English, `x.fr.html` in French) and the theme of Transmission |
| `tests/` | unit tests, translation check, test image, integration tests |
| `tools/preview.sh` | the screens of the menus with example data |
| `docs/` | this documentation and its captures (left out of the published archives) |

Every module follows the same idea:

1. read the wanted state in `/etc/seedtunnel`;
2. generate the configuration files;
3. only replace the ones that changed (`write_if_changed`);
4. only restart the services concerned.

`seedtunnel apply` does these steps again for everything installed. `seedtunnel update` runs it after each update.

## Translations

Messages are written in English, right in the code, as `printf` formats:

```bash
ok 'Client "%s" created.' "$name"
```

In French, each format is looked up in `lang/fr.txt`, where each English line (`en: …`) is followed by its translation (`fr: …`). A missing translation shows the English text. Long texts (help, summaries) are functions in `lang/en.sh` and `lang/fr.sh`.

`make i18n` checks that every message has its translation, with the same `%s`; `python3 tests/i18n_check.py --missing` prints the missing ones, ready to fill in.

## Tests

Locally: `make check` (shellcheck, shfmt, translations, unit tests; it needs `shellcheck`, `shfmt`, `python3`, `inotify-tools` and `qrencode`), and `make fmt` to format the code.

On every push to GitHub, `.github/workflows/ci.yml` runs these checks again, then starts a clean Debian 12, Debian 13, Ubuntu 24.04 and Ubuntu 26.04 (containers with systemd) and runs `tests/integration.sh` in them, which:

- checks on Ubuntu that nothing is installed while ufw is on;
- installs the VPN and the seedbox for real, and checks that running them again changes nothing;
- opens a **real WireGuard tunnel**;
- logs in over **SFTP** with a password then with a key, and checks the lockdown;
- tests the web interface and its pages, adds a **torrent** through `watch/`;
- checks that a **download link** only works once;
- checks that fail2ban bans from every port, and the **full disk protection**;
- tests the **firewall from the outside**;
- makes **backups**, uninstalls everything, **restores**, and checks that the old VPN client reconnects and that the torrents are back.

`tests/unit.sh` also keeps the bugs found in the past, so that they never come back.

## Captures

The captures in `docs/screens/` are the real screens: `tools/preview.sh --all --color` draws them with example data (address `203.0.113.10`, domain `seed.example.net`, account `lancelot`), then they are turned into images. To be made again when a screen shown changes.

## Publishing a version

1. Update `APP_VERSION` in `lib/common.sh`, for example `1.1.0`.
2. Add a `## [1.1.0]` section to `CHANGELOG.md`.
3. Change `V=` in the installation block of `README.md`, `README.fr.md` and of both guides.
4. Push to `master`.

`.github/workflows/release.yml` sees that a new version is not published yet. It runs all the tests again, then creates the tag `v1.1.0` and publishes the archive, `SHA256SUMS` and the attestation of the archive. The release notes come from the section of `CHANGELOG.md`. This is where `seedtunnel update` looks for new versions. Development versions (with a dash, like `1.1.0-dev`) are never published.

The repository `seedtunnel update` asks is set by `APP_REPO` in `lib/common.sh`. For a copy (fork), change it, as well as the links of the README and of these pages.

## License

GPL-3.0-or-later since 1.0.0 (0.9.0 was under MIT). Copyright © 2016-2026 FinalCut.
