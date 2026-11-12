# SeedTunnel — Développement

*[English version](development.md)* · [← Retour au README](../README.fr.md)

### Organisation

| Fichier | Rôle |
|---|---|
| `seedtunnel.sh` | point d'entrée : options, commandes |
| `lib/common.sh` | affichage, saisie, journal, fichier de configuration, apt |
| `lib/i18n.sh` | traductions |
| `lib/ui.sh` | affichage des menus : en-tête, blocs, menus, tableaux, cadres (largeurs en caractères) |
| `lib/menu.sh` | accueil et menu principal |
| `lib/vpn.sh` | WireGuard |
| `lib/seedbox.sh` | Transmission, nginx, Let's Encrypt, SFTP, fail2ban |
| `lib/firewall.sh` | pare-feu nftables |
| `lib/share.sh` | liens de téléchargement à usage unique |
| `lib/diskguard.sh` | protection contre le disque plein |
| `lib/backup.sh` | sauvegardes et restauration |
| `lib/update.sh` | mise à jour, réapplication de la configuration |
| `lib/doctor.sh` | diagnostic |
| `lang/` | messages en français (`fr.txt`) et textes longs (`en.sh`, `fr.sh`) |
| `tests/` | tests unitaires, vérification des traductions, image de test (Debian ou Ubuntu), tests d'intégration |
| `tools/preview.sh` | les écrans des menus avec des données d'exemple |
| `docs/` | cette documentation et les écrans du README (hors des archives publiées) |

Chaque module suit le même principe :
1. lire l'état voulu dans `/etc/seedtunnel` ;
2. générer les fichiers de configuration ;
3. ne remplacer que ceux qui ont changé (`write_if_changed`) ;
4. ne redémarrer que les services concernés.

`seedtunnel apply` refait ces étapes pour tout ce qui est installé. `seedtunnel update` le lance après chaque mise à jour.

### Traductions

Les messages sont écrits en anglais, directement dans le code, comme formats `printf` :

```bash
ok 'Client "%s" created.' "$name"
```

En français, chaque format est cherché dans `lang/fr.txt`, un simple fichier texte où chaque ligne anglaise (`en: …`) est suivie de sa traduction (`fr: …`). Une traduction manquante affiche simplement le texte anglais. Les textes longs (aide, récapitulatifs) sont des fonctions dans `lang/en.sh` et `lang/fr.sh`.

`make i18n` vérifie que chaque message a sa traduction, avec les mêmes `%s` ; `python3 tests/i18n_check.py --missing` affiche celles qui manquent, prêtes à remplir.

### Tests automatiques

À chaque envoi sur GitHub, `.github/workflows/ci.yml` :

1. analyse le code avec **shellcheck**, vérifie la mise en forme avec **shfmt** et les traductions, puis lance les **tests unitaires** (`tests/unit.sh` : des bugs trouvés par le passé, pour qu'ils ne reviennent jamais) ;
2. lance une Debian 12, une Debian 13, une Ubuntu 24.04 et une Ubuntu 26.04 vierges (conteneurs avec systemd), puis y exécute `tests/integration.sh`, qui :
   - vérifie sur Ubuntu que rien n'est installé tant que ufw est actif ;
   - installe le VPN et la seedbox pour de vrai, et vérifie l'**idempotence** ;
   - ouvre un **vrai tunnel WireGuard** ;
   - se connecte en **SFTP** par mot de passe puis par clé, et vérifie l'enfermement ;
   - teste l'interface web, ajoute un **torrent** par le dossier `watch/` ;
   - vérifie qu'un **lien de téléchargement** ne sert qu'une fois, même avec une autre forme de l'adresse ;
   - vérifie que fail2ban bannit de tous les ports, et la **protection contre le disque plein** ;
   - teste le **pare-feu depuis l'extérieur** ;
   - fait des **sauvegardes**, dont hebdomadaires, en télécharge une, désinstalle tout, **restaure** et vérifie que l'ancien client VPN se reconnecte et que les torrents sont revenus.

En local : `make check` (il faut `shellcheck`, `shfmt`, `python3`, `inotify-tools` et `qrencode`), et `make fmt` pour remettre le code en forme.

### Publier une version

1. Mettez à jour `APP_VERSION` dans `lib/common.sh`, par exemple `1.1.0`.
2. Ajoutez une section `## [1.1.0]` dans `CHANGELOG.md`.
3. Changez `V=` dans le bloc d'installation de `README.md` et `README.fr.md`.
4. Envoyez sur `master`.

`.github/workflows/release.yml` voit qu'une nouvelle version n'est pas encore publiée. Il relance tous les tests, puis crée l'étiquette `v1.1.0` et publie sur GitHub l'archive, `SHA256SUMS` et l'attestation de l'archive. C'est là que `seedtunnel update` va chercher les nouvelles versions. Envoyer soi-même une étiquette `v1.1.0` fonctionne aussi. Les versions de développement (avec un tiret, comme `1.1.0-dev`) ne sont jamais publiées.

Le dépôt interrogé par `seedtunnel update` est défini par `APP_REPO` dans `lib/common.sh`. En cas de renommage du dépôt ou de copie (fork), adaptez-le, ainsi que les liens du README et de ces pages.
