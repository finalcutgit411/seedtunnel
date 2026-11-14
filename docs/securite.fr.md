# SeedTunnel — Sécurité

*[English version](security.md)* · [← Retour au README](../README.fr.md)

## Ce que SeedTunnel protège

- L'interface de contrôle de Transmission (RPC) n'écoute que sur `127.0.0.1` : on y accède par nginx, et le mot de passe est vérifié deux fois, par nginx puis par Transmission. Seul son port BitTorrent (60000) est ouvert aux pairs.
- Transmission est **enfermé par systemd** (`ProtectSystem=strict`…) : il ne peut écrire que dans ses dossiers, et ne peut rien lancer depuis les dossiers où lui ou l'utilisateur SFTP écrivent. Il ne lance aucun programme à la fin d'un téléchargement (l'interface web pourrait en activer un : `seedtunnel apply` le désactive à nouveau, `seedtunnel doctor` le signale). Ses réglages, qui contiennent le hash du mot de passe, ne sont lisibles que par son propre compte.
- Les **clients du VPN ne peuvent pas se joindre entre eux**, et rien ne les atteint depuis l'extérieur du tunnel, sauf les réponses à leurs propres connexions et leur port ouvert (60001 et suivants). Pare-feu activé ou non.
- **Docker sur le même serveur garde sa protection** : pour que les clients du VPN aient Internet, SeedTunnel n'ajoute dans `DOCKER-USER` que deux règles limitées au réseau du VPN (10.8.0.0/24). Rien n'ouvre l'accès aux conteneurs, et les réglages de Docker ne sont pas modifiés.
- Les mots de passe ne sont **jamais écrits en clair**, ni passés en argument d'une commande : seuls leurs hash sont gardés. Seule exception : la passphrase de la sauvegarde hebdomadaire, si vous l'activez, enregistrée lisible par root uniquement pour que la sauvegarde tourne seule. Chaque sauvegarde la contient aussi, pour qu'une restauration garde la sauvegarde hebdomadaire en marche : qui peut ouvrir une sauvegarde peut ouvrir les hebdomadaires. Prenez le même soin de la passphrase de chaque sauvegarde.
- L'utilisateur SFTP est enfermé dans le dossier des données : pas de shell, pas de tunnel. Si sshd ne lui applique pas toutes ces restrictions, depuis le serveur, par le VPN et depuis Internet (un bloc `Match` placé avant elles dans `sshd_config`, par exemple), le compte est suspendu plutôt que laissé sans elles. En mode « clés uniquement », on vérifie aussi que sshd refuse les mots de passe (y compris `keyboard-interactive`).
- Les fichiers qui peuvent contenir un secret (`--config`, `SEEDBOX_PASSWORD_FILE`, `--passphrase-file`) sont refusés si quelqu'un d'autre que root peut les lire.
- Avec un certificat auto-signé, chaque lien de téléchargement est donné avec son empreinte SHA-256, à vérifier avant d'accepter l'alerte du navigateur.
- fail2ban bannit les attaquants de SSH de **tous les ports TCP**, quel que soit le port de SSH. Le VPN (UDP) leur reste ouvert, mais demande une clé : banni par erreur, vous revenez par lui ([guide](guide.fr.md#banni-de-ssh--revenez-par-le-vpn)).
- Réglages réseau du noyau durcis (`/etc/sysctl.d/90-seedtunnel-network.conf`) : redirections ICMP ignorées, routage par la source refusé.
- La configuration SSH est vérifiée (`sshd -t`) avant d'être rechargée. En cas d'erreur, la version précédente est remise.
- TLS 1.2/1.3 uniquement. HSTS n'est activé qu'avec un vrai certificat.
- Mises à jour de sécurité automatiques (`unattended-upgrades`).
- `/etc/seedtunnel` et les sauvegardes sont lisibles par root uniquement, comme les réglages qu'une restauration a remplacés (`/etc/seedtunnel.before-restore-…`, anciennes clés et passphrase comprises). `seedtunnel doctor` les signale jusqu'à leur suppression : Sauvegarde / restauration → « Mes sauvegardes », ou `seedtunnel restore clean`.
- Une sauvegarde faite par quelqu'un d'autre ne peut rien lancer à la restauration : aucun fichier exécutable, seulement les réglages de SeedTunnel avec des valeurs qu'il accepterait, des noms de clients VPN valides, tous les fichiers à root, et de Let's Encrypt seulement le certificat de SeedTunnel, renouvelé sans autre commande que le rechargement de nginx.
- root n'écrit jamais là où le compte de Transmission (ou l'utilisateur SFTP) pourrait le mener avec un lien : les réglages de Transmission et les torrents remis sont écrits par son propre compte.
- Le jeton d'un lien de téléchargement, son mot de passe, ne figure dans aucun argument de commande (`ps` et `systemctl status` les montrent à tous les comptes), pas plus que le hash du mot de passe de la seedbox.

## Ce que SeedTunnel ne garantit pas

- **Le VPN ne rend pas anonyme.** Il chiffre tout entre votre appareil et le serveur ; ensuite, les sites voient l'adresse du serveur, et l'hébergeur voit passer le trafic comme celui de n'importe quel serveur.
- **Un serveur n'est jamais invulnérable.** SeedTunnel tourne en root : la sécurité de vos comptes SSH reste la vôtre (mot de passe solide, ou mieux, une clé).
- **Une sauvegarde ne vaut que si elle est ailleurs.** Gardez-en une copie et la passphrase hors du serveur : sans la passphrase, elle ne s'ouvre pas.
- **Les autres logiciels** installés à la main sur le serveur demandent leurs propres précautions.
