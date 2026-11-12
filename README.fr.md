<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/banner-fr-dark.svg">
    <img src="docs/banner-fr-light.svg" alt="SeedTunnel. Votre propre VPN et votre seedbox, sur votre serveur. Une commande. Sans Docker. Rien de caché." width="640">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/finalcutgit411/seedtunnel/actions/workflows/ci.yml"><img src="https://github.com/finalcutgit411/seedtunnel/actions/workflows/ci.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/finalcutgit411/seedtunnel/releases/latest"><img src="https://img.shields.io/github/v/release/finalcutgit411/seedtunnel?label=version" alt="Dernière version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/finalcutgit411/seedtunnel?label=licence" alt="Licence MIT"></a>
</p>

<p align="center">Par FinalCut · <a href="README.md">English</a></p>

<p align="center"><img src="docs/screens/fr-home.png" alt="L'accueil de SeedTunnel : le VPN, la seedbox, le pare-feu, le disque et les sauvegardes d'un coup d'œil" width="760"></p>

<table>
  <tr>
    <td width="33%" valign="top"><b>Simple</b><br>Un menu dans votre terminal. Ajouter un téléphone au VPN et scanner son QR code, connecter WinSCP, faire une sauvegarde : quelques touches à chaque fois.</td>
    <td width="33%" valign="top"><b>Sûr</b><br>Pare-feu, HTTPS, fail2ban, sauvegardes chiffrées, SFTP enfermé dans son dossier. Rien n'est ouvert sans que vous l'ayez demandé.</td>
    <td width="33%" valign="top"><b>Léger</b><br>Du bash et les paquets de votre distribution. Ni Docker, ni base de données. 1 Go de RAM suffit.</td>
  </tr>
</table>

## Démarrage rapide

Louez un petit VPS sous Debian 12/13 ou Ubuntu Server 24.04/26.04, connectez-vous en SSH, puis collez ceci en root (ou après `sudo -i`) :

```bash
apt update && apt full-upgrade -y
V=1.0.0
cd "$(mktemp -d)"
curl -fLO https://github.com/finalcutgit411/seedtunnel/releases/download/v$V/seedtunnel-$V.tar.gz \
  && curl -fLO https://github.com/finalcutgit411/seedtunnel/releases/download/v$V/SHA256SUMS \
  && sha256sum -c SHA256SUMS \
  && tar -xzf seedtunnel-$V.tar.gz \
  && mv seedtunnel-$V /opt/seedtunnel \
  && /opt/seedtunnel/seedtunnel.sh
```

Sur Ubuntu, désactivez d'abord ufw (`ufw disable`) : SeedTunnel apporte son propre pare-feu.

Le menu s'ouvre à la fin et ne demande que le nécessaire. Ensuite, tapez `seedtunnel` pour le rouvrir.

## Ce que vous obtenez

| | |
|---|---|
| **VPN WireGuard** | Un QR code par téléphone, un lien de téléchargement à usage unique par ordinateur (avec la seedbox), un port ouvert par client pour vos torrents, pas de fuite IPv6. |
| **Seedbox** | Transmission dans votre navigateur, en HTTPS, avec un certificat Let's Encrypt qui se renouvelle tout seul. Vos fichiers en SFTP, avec des profils prêts à importer dans WinSCP et FileZilla, et une clé SSH créée pour vous si vous n'en avez pas. |
| **Protection** | Pare-feu nftables, fail2ban, mots de passe gardés seulement sous forme de hachages, mises à jour de sécurité automatiques, arrêt propre de Transmission avant que le disque soit plein. |
| **Entretien** | Un diagnostic complet, des sauvegardes chiffrées chaque semaine, des mises à jour vérifiées avec retour arrière, et un rapport anonymisé à partager quand vous demandez de l'aide. |

<p align="center">
  <img src="docs/screens/fr-add.png" alt="Un nouveau client du VPN : son adresse, son port ouvert, son DNS et son fichier" width="49%">
  <img src="docs/screens/fr-client.png" alt="Installer le tunnel sur un téléphone ou un ordinateur, le port pour le torrent, le kill switch" width="49%">
</p>
<p align="center">
  <img src="docs/screens/fr-sftp.png" alt="Connexion SFTP : les réglages, les profils WinSCP et FileZilla, les clés SSH expliquées" width="49%">
  <img src="docs/screens/web.png" alt="L'interface web de Transmission aux couleurs de SeedTunnel" width="49%">
</p>

## Est-ce pour vous ?

**Oui**, si vous louez un VPS KVM ou un serveur dédié, même petit, et que vous voulez :

- votre propre seedbox, sans y passer un week-end ;
- un VPN pour vos téléphones et ordinateurs (Wi-Fi public, voyage, famille), avec ou sans la seedbox ;
- savoir exactement ce qui tourne en root sur votre serveur.

**Non**, si vous cherchez Sonarr, Radarr, Plex et compagnie, une seedbox à plusieurs comptes, ou tout dans Docker. SeedTunnel reste petit, et c'est voulu : un Transmission, un compte SFTP, un VPN. Pour Sonarr, Radarr ou Plex, regardez plutôt [swizzin](https://swizzin.ltd/).

## Pourquoi lui faire confiance

- **Vous pouvez le lire.** Du bash de haut en bas : commencez par `seedtunnel.sh`, puis `lib/`. L'archive est contrôlée par son empreinte SHA-256 avant que rien ne soit lancé.
- **Vous pouvez le réparer.** `seedtunnel doctor` passe tout le serveur en revue et donne, pour chaque problème, la commande qui le corrige. `seedtunnel update back` revient à la version précédente.
- **Vous ne pouvez pas vous enfermer dehors.** Le pare-feu s'active à l'essai : sans nouvelle connexion SSH de votre part dans les 2 minutes, il se retire tout seul.
- **Vous pouvez déménager.** Les sauvegardes chiffrées se restaurent sur le même serveur ou sur un nouveau, même d'Ubuntu vers Debian.
- **Il est testé.** Chaque changement passe plus de 250 tests unitaires et une installation complète sur Debian 12 et 13, Ubuntu Server 24.04 et 26.04.

<p align="center"><img src="docs/screens/fr-diagnostic.png" alt="Un diagnostic complet : tout est en ordre" width="560"></p>

## Au quotidien

Tout est dans le menu (`seedtunnel`). Les mêmes actions existent aussi en commandes, en root ou avec `sudo` :

| Commande | Ce qu'elle fait |
|---|---|
| `seedtunnel vpn add telephone --qr` | Ajoute un client VPN et affiche son QR code |
| `seedtunnel vpn share pc-bureau` | Lien de téléchargement à usage unique pour le fichier d'un client (avec la seedbox) |
| `seedtunnel seedbox sftp-config winscp` | Lien à usage unique vers un profil WinSCP (ou `filezilla`) |
| `seedtunnel doctor` | Vérifie tout, avec la correction de chaque problème |
| `seedtunnel doctor --link` | La même chose, avec un rapport anonymisé à partager |
| `seedtunnel backup` / `backup share` | Sauvegarde chiffrée / lien de téléchargement à usage unique |
| `seedtunnel restore [FICHIER]` | Restaure une sauvegarde, sur ce serveur ou sur un nouveau |
| `seedtunnel update` / `update back` | Mise à jour vérifiée / retour à la version précédente |

<details>
<summary><b>Ce qu'il change sur votre serveur</b></summary>

- **Paquets** : uniquement ceux de votre distribution (WireGuard, Transmission, nginx, certbot, fail2ban, nftables et quelques outils). SeedTunnel note ceux qu'il a installés et les retire à la désinstallation.
- **Un compte** : le compte SFTP de la seedbox, sans accès au shell.
- **Ses fichiers** : le code dans `/opt/seedtunnel` (la commande `seedtunnel` dans `/usr/local/bin`), les réglages dans `/etc/seedtunnel` (root uniquement), le journal dans `/var/log/seedtunnel.log` (archivé chaque mois), les téléchargements dans `/srv/seedbox`, les sauvegardes dans `/var/backups/seedtunnel`.
- **Réglages du système**, dans des fichiers à son nom : WireGuard, Transmission, nginx (son site, le site par défaut désactivé), fail2ban, SSH (le compte SFTP enfermé), AppArmor (dossier de Transmission), réglages réseau du noyau, services et minuteries systemd (pare-feu, sauvegarde hebdomadaire, protection du disque plein), archivage des journaux, mises à jour de sécurité automatiques.
- **Désinstallation** : retire ce que SeedTunnel a installé. Vos sauvegardes restent, et vos téléchargements aussi, sauf si vous demandez à les supprimer.

</details>

<details>
<summary><b>Limites connues</b></summary>

- Serveurs virtuels KVM et serveurs dédiés uniquement, pas les conteneurs OpenVZ ou LXC.
- Sur Ubuntu, ufw doit être désactivé (voir [Démarrage rapide](#démarrage-rapide)).
- Docker sur le même serveur peut bloquer le trafic du VPN. `seedtunnel doctor` le détecte et dit quoi changer ; SeedTunnel ne touche jamais aux règles de Docker.

</details>

## Besoin d'aide ?

Ouvrez une [issue sur GitHub](https://github.com/finalcutgit411/seedtunnel/issues) et joignez le rapport de `seedtunnel doctor --link` : votre adresse IP, votre domaine et vos noms de comptes y sont remplacés.

## Documentation

- [Guide](docs/guide.fr.md) : chaque menu et chaque commande
- [Sécurité](docs/securite.fr.md) : comment le serveur est protégé
- [Développement](docs/developpement.fr.md) : tests et traductions
- [Historique des versions](CHANGELOG.md)

## Crédits

**FinalCut** : auteur de SeedTunnel, créé en 2016 et réécrit en 2026.

## Licence

[MIT](LICENSE).
