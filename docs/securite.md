# Modèle de sécurité

Ce que SeedTunnel protège, comment, et ce qu'il ne protège pas.

## Hypothèses

- Le serveur est dédié à SeedTunnel, sous Debian 13, administré par root.
  Quiconque obtient root sur le serveur contrôle tout ce qui y est conservé.
- SeedTunnel tourne en root : il ne lit jamais une configuration, une
  sauvegarde ou une archive comme du code. Le fichier de configuration est lu
  ligne par ligne, chaque valeur est vérifiée, et rien n'est exécuté.
- Les réglages sont dans `/etc/seedtunnel` (dossier 700, fichiers 600, root),
  le journal dans `/var/log/seedtunnel.log`. Les mises à jour de sécurité de
  Debian sont activées (`unattended-upgrades`).

## Exposition réseau

- **Pare-feu** (`firewall enable`) : tout est refusé, sauf SSH, le VPN, la
  seedbox (80 et 443), les réponses aux connexions ouvertes et ICMP. Le
  durcissement du noyau refuse les redirections ICMP et le routage par la
  source.
- **Transmission** n'écoute que sur `127.0.0.1`. Il est confiné par systemd
  (`ProtectSystem=strict`…). Le seul accès au RPC passe par
  nginx, en HTTPS et avec un mot de passe.
- **fail2ban** bannit les attaques sur SSH et SFTP, sur le mot de passe web,
  puis les récidivistes (prisons `sshd`, `nginx-http-auth`, `recidive`).
- **Liens de téléchargement** : jeton aléatoire de 128 bits, un seul
  téléchargement, expiration après 10 minutes. Le fichier est effacé dès que
  nginx l'ouvre, et tout est dans `/run`, vidé au démarrage. Ouvrir la page
  (aperçu d'une messagerie) ne consomme pas le lien.

## Accès au serveur

- **SSH** : root n'entre jamais en SSH. Les mots de passe peuvent être
  refusés (clés seulement). Chaque changement est mis à l'essai 2 minutes et
  gardé seulement après une nouvelle connexion réussie ; sinon, il s'annule.
  SeedTunnel ne modifie qu'un fichier de `/etc/ssh/sshd_config.d`, lu avant
  les autres.
- **SFTP** : le compte de la seedbox est enfermé dans le dossier des données
  (`chroot`), sans shell, sans tunnel ni redirection. SeedTunnel vérifie ces
  restrictions telles que sshd les applique (`sshd -T`), d'où que vienne la
  connexion.
- **Pare-feu et SSH** : une règle qui couperait l'accès est annulée seule
  au bout de 2 minutes.

## Secrets

- Les mots de passe ne sont jamais conservés en clair : seules leurs
  empreintes (système, nginx, Transmission) sont gardées, dans
  `/etc/seedtunnel/seedbox.secrets`.
- Les mots de passe, phrases de passe et clés privées n'entrent jamais dans le
  journal ni dans le rapport de `doctor --link`.

## Mises à jour

- Chaque version est une archive publiée sur GitHub, avec ses sommes
  `SHA256SUMS` signées par une clé Ed25519 de publication. Cette clé est
  gardée hors ligne par le mainteneur, jamais sur GitHub.
- `seedtunnel update` refuse toute version sans signature valide de cette
  clé, ou dont l'archive ne correspond pas à sa somme. Téléchargement en
  HTTPS seulement, redirections comprises. L'archive est vérifiée avant
  extraction (ni lien, ni chemin absolu, ni `..`), puis extraite en root avec
  des droits 755/644.
- Une nouvelle clé n'arrive que par une version signée par la clé en place.
  Détails : [mise à jour](mise-a-jour.md).

## Sauvegardes

- Chiffrement AES-256-CBC, clé dérivée de la phrase de passe (PBKDF2,
  600 000 itérations). Sans la phrase de passe, la sauvegarde est illisible.
- La restauration ne reprend que ce que SeedTunnel sauvegarde (liste fixe de
  chemins). Elle vérifie chaque réglage, ferme les droits des fichiers
  extraits et n'exécute rien de l'archive.

## Limites connues

- **Première installation** : la clé publique de vérification vient du
  README, servi par GitHub. Un compte GitHub compromis pourrait publier une
  autre clé dans le README. Les installations existantes, elles, gardent la
  clé de leur version.
- **Clé de publication perdue** : aucune nouvelle version ne peut être
  acceptée ; chaque serveur doit être réinstallé à la main.
- **Clés des clients VPN** : leurs clés privées restent sur le serveur
  (`/etc/seedtunnel/vpn/clients/`), pour pouvoir réafficher un QR code. Un
  serveur compromis permet donc d'usurper les clients : il faut alors les
  révoquer et les recréer.
- **Clés SSH créées sur le serveur** (`ssh key new`, `seedbox sftp-key new`) :
  sans phrase de passe, avec une copie dans `/run` jusqu'au téléchargement ou
  pendant 10 minutes au plus. Mieux vaut créer la clé sur votre ordinateur et
  l'ajouter avec `ssh key add` ou `seedbox sftp-key add`.
- **Un seul mot de passe** pour l'interface web, le SFTP et Transmission. Le
  RPC de Transmission en garde une empreinte SHA-1 salée dans
  `settings.json`, qui est sauvegardé. Si ce fichier fuit, le mot de passe
  peut être cassé hors ligne : choisissez-le long.
- **Sauvegardes sans authentification** (pas de MAC). Sans la phrase de
  passe, une sauvegarde modifiée ne donne que des données illisibles,
  refusées à la restauration. Avec la phrase de passe, un MAC n'apporterait
  rien de plus.
- **Sauvegardes sur le même disque** (`/var/backups/seedtunnel`) : si le
  serveur disparaît, elles disparaissent avec lui. Téléchargez-en une copie
  (`backup share`).
- **Alertes seulement à la connexion SSH** (voir le guide, « Diagnostic ») :
  aucun courriel ni notification. Un problème reste inaperçu tant que
  personne ne se connecte.
- **Hors du tunnel** : si le tunnel tombe, l'appareil continue sans lui. Le
  blocage (kill switch) se règle sur chaque appareil.
