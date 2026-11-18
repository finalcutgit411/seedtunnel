# Désinstallation

SeedTunnel retire chaque partie séparément, ou tout en une seule commande
(`seedtunnel uninstall`, plus bas). La fin de cette page liste ce qui reste
après le retrait des parties.

## Retirer la seedbox

```bash
seedtunnel seedbox uninstall
seedtunnel seedbox uninstall --yes --purge-data   # sans question, données comprises
```

- Retiré : le compte SFTP, Transmission, le site nginx, le certificat
  Let's Encrypt, la protection du disque, la prison fail2ban de l'interface
  web (et fail2ban lui-même si le VPN n'est pas installé). Sont aussi
  désinstallés les paquets que SeedTunnel avait installés lui-même (nginx,
  certbot…), jamais ceux qui étaient déjà là.
- Les **données** restent dans leur dossier, sauf si vous demandez leur
  suppression (question dans le menu, `--purge-data` en commande). Seuls les
  dossiers créés par SeedTunnel (`complete`, `incomplete`, `watch`,
  `documents`) sont alors supprimés, puis le dossier s'il est vide. Un
  fichier que SeedTunnel n'a pas créé est gardé, et c'est signalé.
- Fermez d'abord WinSCP ou FileZilla : leurs reconnexions automatiques
  compteraient comme des échecs, et fail2ban pourrait bannir votre adresse.

## Retirer le VPN

```bash
seedtunnel vpn uninstall
```

- **Tous les clients** sont supprimés : leurs fichiers et QR codes ne
  fonctionnent plus. Le site des liens est retiré aussi.
- Retirés : WireGuard, ses règles de NAT, le passage par Docker s'il y en
  avait un. Les paquets installés par SeedTunnel (`wireguard-tools`,
  `qrencode`) sont désinstallés, ainsi que fail2ban si la seedbox n'est plus
  là. Le routage IPv4 est coupé au prochain redémarrage.
- Une session SSH ouverte **à travers le VPN** est coupée dès l'arrêt de
  WireGuard. Connectez-vous d'abord par l'adresse publique du serveur
  (coupez le tunnel sur votre poste).

Quand la dernière partie (VPN ou seedbox) est retirée, la sauvegarde
hebdomadaire s'arrête et sa phrase de passe enregistrée est supprimée. Les
sauvegardes déjà faites restent.

## Couper le pare-feu

```bash
seedtunnel firewall disable
```

Tous les ports du serveur redeviennent joignables. Sans VPN ni seedbox, le
pare-feu reste sinon actif et n'ouvre plus que SSH.

## Ce qui reste après le retrait des parties

|Emplacement|Contenu|
|-|-|
|`/opt/seedtunnel`, `/opt/seedtunnel.old`|Le code, et la version précédente gardée par la mise à jour.|
|`/usr/local/bin/seedtunnel`|Le raccourci.|
|`/etc/seedtunnel`, `/etc/seedtunnel.before-restore-*`|Réglages restants (langue, liste des paquets installés), et réglages gardés par une restauration.|
|`/var/backups/seedtunnel`|Les sauvegardes chiffrées.|
|`/var/log/seedtunnel.log*`, `/etc/logrotate.d/seedtunnel`|Le journal et sa rotation.|
|`/etc/ssh/sshd_config.d/00-seedtunnel-admin.conf`, `/etc/ssh/seedtunnel_access`|L'accès SSH des administrateurs : root refusé, et les mots de passe si vous les avez refusés.|
|`/etc/apt/apt.conf.d/20auto-upgrades`|Les mises à jour de sécurité automatiques de Debian.|
|Paquets de base|curl, openssl, jq, nftables, unattended-upgrades…|

## Tout retirer

```bash
seedtunnel uninstall
seedtunnel uninstall --yes --purge-data --purge-backups   # sans question, données et sauvegardes comprises
```

Une seule question (non par défaut). La commande retire alors la seedbox, le
VPN, le pare-feu et la sauvegarde hebdomadaire comme leurs propres
commandes, puis le reste de SeedTunnel : ses unités systemd, `/etc/seedtunnel`
et les réglages gardés par les restaurations, le journal et sa rotation, le
raccourci, le code et la version précédente gardée par la mise à jour.

- Gardés : les **sauvegardes** (`--purge-backups` les supprime ; téléchargez
  d'abord celles à garder avec `seedtunnel backup share`), les **données** de
  la seedbox (`--purge-data`), l'**accès SSH** des administrateurs (voir
  plus bas), les paquets de base et les mises à jour automatiques de Debian.
- Si une étape échoue, la commande s'arrête là : relancée, elle reprend.
- Un code installé depuis un dépôt git (`.git` présent) est laissé en place.
- Le raccourci n'est retiré que s'il mène à ce SeedTunnel.

**Accès SSH** : supprimer `00-seedtunnel-admin.conf` rend à sshd les réglages
de Debian, ce qui peut accepter de nouveau root, ou les mots de passe.
Gardez-le, sauf si vous savez ce que vous remplacez. Pour l'enlever malgré
tout, gardez une session SSH ouverte, puis :

```bash
rm -f /etc/ssh/sshd_config.d/00-seedtunnel-admin.conf /etc/ssh/seedtunnel_access
sshd -t && systemctl reload ssh
```

Vérifiez ensuite qu'une **nouvelle** connexion fonctionne avant de fermer la
session ouverte.
