# Guide

Premiers pas avec SeedTunnel sur un serveur Debian 13. Toutes les commandes
se lancent en root (`sudo -i`). Les noms et adresses de ce guide sont des
exemples (`example.org`, `203.0.113.10`).

## Installer

Suivez l'[installation du README](../README.md#installation) : elle vérifie
la signature et l'empreinte de la version téléchargée, puis ouvre le menu.
Au premier lancement, SeedTunnel crée le raccourci `/usr/local/bin/seedtunnel`
et installe ses outils de base (curl, openssl, jq, nftables…).

Pour voir les écrans sans rien installer, ni être root :

```bash
tools/preview.sh            # un écran après l'autre
tools/preview.sh --all      # tous les écrans d'un coup
```

L'aperçu n'utilise que des données d'exemple et ne modifie rien.

## Le menu

`seedtunnel`, sans argument, ouvre le menu. Il a six rubriques :

|Rubrique|Contenu|
|-|-|
|VPN|Clients (ajouter, afficher, lien, révoquer), connexions, site des liens, adresse et port, DNS.|
|Seedbox|Identifiants, domaine et certificat HTTPS, accès SFTP, redémarrage, retrait.|
|Protection|Pare-feu (activer, couper, règles), adresses bannies par fail2ban.|
|Accès et clés|Comptes et clés SSH, profils SFTP, identifiants de la seedbox, règles SSH, mots de passe et root.|
|Diagnostic et maintenance|Diagnostic, mise à jour ou version précédente, redémarrage du serveur.|
|Sauvegardes et restauration|Sauvegarde chiffrée, sauvegarde hebdomadaire, restauration, mes sauvegardes.|

`L` change la langue des messages (français ou anglais). Chaque action existe
aussi en commande : `seedtunnel --help` les liste toutes.

## VPN WireGuard

```bash
seedtunnel vpn install
seedtunnel vpn add telephone --qr
seedtunnel vpn share portable
```

- Le serveur est `10.8.0.1`. Le client numéro N reçoit l'adresse
  `10.8.0.(N+1)` et le port public `60000+N` (TCP et UDP), redirigé vers lui
  quand il est connecté : c'est le port à mettre dans un logiciel torrent
  utilisé derrière le VPN.
- Adresse publique : de préférence un nom de domaine. Si le serveur change,
  il suffit de faire pointer ce nom vers le nouveau : les clients n'ont rien
  à changer.
- `vpn show NOM` réaffiche le QR code et le fichier d'un client.
  `vpn share NOM` donne un lien de téléchargement à usage unique, valable
  10 minutes.
- `vpn dns` change le DNS des clients : Quad9 par défaut, Cloudflare, DNS4EU,
  AdGuard, ou vos propres adresses.
- Sans seedbox, `vpn links on` installe un petit site HTTPS qui sert seulement
  les liens de téléchargement.
- Si le tunnel tombe, l'appareil continue sans lui, avec sa vraie adresse.
  La fiche de chaque client explique comment tout bloquer hors du tunnel
  (kill switch) sous Windows, Android et dans qBittorrent.

## Seedbox Transmission

```bash
seedtunnel seedbox install
```

- L'interface web est servie par nginx en HTTPS, protégée par un mot de passe.
  Transmission n'écoute que sur `127.0.0.1`.
- Certificat Let's Encrypt quand le domaine pointe vers le serveur et que le
  port 80 est joignable. Sinon, certificat auto-signé, et
  `seedbox domain NOM` réessaie plus tard. `--staging` utilise les serveurs
  de test de Let's Encrypt, pour vos essais.
- Dossier des données (le plus grand disque, ou `/srv/seedbox`) :
  `complete` (téléchargements terminés), `incomplete` (en cours), `watch`
  (déposez-y un `.torrent`, il démarre seul), `documents` (espace personnel,
  inaccessible à Transmission).
- SFTP remplace FTP : le compte est enfermé dans le dossier des données, sans
  shell ni tunnel. `seedbox sftp-config winscp` ou `filezilla` donne un
  profil prêt à importer ; `seedbox sftp-key new` crée une clé.
- Protection du disque : sous 3 Go libres, Transmission est arrêté ; il
  repart au-dessus de 5 Go. Un arrêt manuel n'est jamais annulé.
- Un seul mot de passe sert à l'interface web, au SFTP et à Transmission :
  `seedbox password` le change partout.

## Accès SSH

Root n'entre jamais en SSH : les administrateurs se connectent avec leur
propre compte, puis `sudo -i`.

```bash
seedtunnel ssh key add /root/ma-cle.pub debian
seedtunnel ssh root off
seedtunnel ssh password off
```

`ssh root off` et `ssh password off` sont mis à l'essai 2 minutes. Ils ne
sont gardés qu'après une **nouvelle** connexion réussie du compte qui les a
lancés ; sinon, ils s'annulent seuls. Gardez donc une deuxième session ouverte
et testez la connexion depuis une nouvelle fenêtre. `ssh rules` montre ce que
sshd applique vraiment.

## Pare-feu

```bash
seedtunnel firewall enable
seedtunnel firewall rules
```

Tout ce qui arrive au serveur est refusé, sauf : SSH (les ports réellement
utilisés), le VPN et la seedbox s'ils sont installés, les réponses aux
connexions déjà ouvertes, et ICMP. Comme pour SSH, l'activation est mise à
l'essai 2 minutes et confirmée depuis une nouvelle connexion SSH. Les règles
de SeedTunnel ont leur propre table : celles de fail2ban ou de Docker restent
en place.

## Diagnostic

```bash
seedtunnel doctor          # code de sortie 1 si un problème est trouvé
seedtunnel doctor --link   # rapport sans données privées, lien unique
```

Le rapport de `doctor --link` remplace par des mots génériques le domaine, le
nom du serveur, les adresses IP publiques, le compte SFTP, les clés SSH et
les noms des clients VPN. Il peut être transmis pour obtenir de l'aide.
Journal : `/var/log/seedtunnel.log`.

À chaque connexion SSH, quelques lignes signalent ce qui demande un coup
d'œil : seedbox arrêtée parce que le disque est presque plein, sauvegarde
hebdomadaire en échec ou absente depuis plus de 8 jours, certificat HTTPS
expiré ou valable moins de 14 jours. Rien ne s'affiche quand tout va bien.
Ce message vient de `/etc/update-motd.d/90-seedtunnel`, installé avec le VPN
ou la seedbox. Il ne vérifie que l'état local, sans accès au réseau. Aucun
courriel n'est envoyé.

## Configuration par fichier

```bash
cp /opt/seedtunnel/examples/seedtunnel.conf /root/mon-serveur.conf
chmod 600 /root/mon-serveur.conf
seedtunnel vpn install --config /root/mon-serveur.conf
seedtunnel seedbox install --config /root/mon-serveur.conf
```

Le fichier est lu ligne par ligne, jamais exécuté. Relancer la même commande
avec le même fichier ne casse rien : SeedTunnel remet tout en ordre.
`seedtunnel apply` réapplique la configuration enregistrée.

## Pour aller plus loin

- [Modèle de sécurité](securite.md)
- [Services tiers](services-tiers.md)
- [Mise à jour](mise-a-jour.md)
- [Sauvegarde et restauration](sauvegarde.md)
- [Désinstallation](desinstallation.md)
