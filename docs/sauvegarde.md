# Sauvegarde et restauration

## Ce qui est sauvegardé

Une sauvegarde est une archive chiffrée (`.tar.gz.enc`) qui contient :

- `/etc/seedtunnel` : clés et clients du VPN, réglages et empreintes des mots
  de passe de la seedbox, pare-feu ;
- les certificats Let's Encrypt ;
- les clés SSH du compte SFTP ;
- l'état de Transmission : liste des torrents et réglages.

Ne sont **pas** sauvegardés :

- les fichiers téléchargés : copiez-les à part (`rsync`, SFTP) ;
- les comptes et clés SSH des administrateurs, ni le refus de root. Sur un
  nouveau serveur, les comptes ne sont pas les mêmes, et refuser root
  pourrait le fermer.

## Sauvegarder

```bash
seedtunnel backup
seedtunnel backup --output /root/ma-sauvegarde.tar.gz.enc
seedtunnel backup --passphrase-file /root/phrase-de-passe
```

- La phrase de passe fait au moins 12 caractères. Sans elle, la sauvegarde
  ne peut pas être restaurée : notez-la ailleurs que sur le serveur.
- Chiffrement AES-256-CBC, clé dérivée de la phrase de passe (PBKDF2,
  600 000 itérations). Chaque sauvegarde est relue après son écriture.
- Les sauvegardes vont dans `/var/backups/seedtunnel`. Le fichier donné à
  `--passphrase-file` doit appartenir à root et n'être lisible que par lui
  (`chmod 600`).

## Sauvegarde hebdomadaire

```bash
seedtunnel backup auto on
seedtunnel backup auto status
```

Un minuteur systemd fait une sauvegarde chiffrée chaque semaine (rattrapée
au démarrage si le serveur était éteint) et garde les 4 dernières. Sa phrase
de passe est enregistrée sur le serveur (`/etc/seedtunnel/backup.passphrase`,
root seulement) : notez-la aussi ailleurs.

## Garder une copie hors du serveur

Les sauvegardes restent sur le disque du serveur : s'il disparaît, elles
disparaissent avec lui.

```bash
seedtunnel backup list
seedtunnel backup share        # lien unique pour la dernière sauvegarde
seedtunnel backup share 2      # ou pour la sauvegarde numéro 2
```

Le lien sert un seul téléchargement et expire après 10 minutes.
`seedtunnel doctor` rappelle quand aucune sauvegarde n'a été téléchargée
depuis un mois. `backup delete NUMÉRO` supprime une sauvegarde de la liste.

## Restaurer

Sur un nouveau serveur Debian 13, installez SeedTunnel
([README](../README.md#installation)), copiez la sauvegarde dans `/root`
(WinSCP, `scp`), puis :

```bash
seedtunnel restore                                  # liste des sauvegardes trouvées
seedtunnel restore /root/ma-sauvegarde.tar.gz.enc
seedtunnel restore /root/ma-sauvegarde.tar.gz.enc --passphrase-file /root/phrase-de-passe --yes
```

- La restauration remet tout en place et installe ce qui manque. Les clients
  VPN continuent de fonctionner sans changement si l'adresse du serveur
  (idéalement un nom de domaine) pointe vers le nouveau serveur.
- Les sauvegardes sont cherchées dans `/var/backups/seedtunnel`, `/root` et
  les dossiers personnels.
- Seuls les chemins que SeedTunnel sauvegarde sont repris. Chaque réglage est
  vérifié, les droits des fichiers sont refermés, et rien de l'archive n'est
  exécuté.
- Un serveur qui a déjà un VPN ou une seedbox absents de la sauvegarde est
  refusé : retirez-les d'abord, ou restaurez sur un nouveau serveur.
- Les réglages remplacés sont gardés dans
  `/etc/seedtunnel.before-restore-AAAAMMJJ-HHMMSS`, au cas où il faudrait
  revenir en arrière. `seedtunnel restore clean` les supprime une fois la
  restauration validée.
- Si la restauration s'arrête en route (erreur, Ctrl+C, coupure), le menu et
  `seedtunnel doctor` le signalent, et le message donne la commande pour
  revenir à l'état d'avant (`bash /etc/seedtunnel.before-restore-….undo`).

## Limites

- Le format de sauvegarde n'a pas d'authentification (pas de MAC). Sans la
  phrase de passe, une sauvegarde modifiée ne donne que des données
  illisibles, refusées à la restauration. Avec la phrase de passe, un MAC
  n'apporterait rien de plus.
- L'avancement des torrents n'est pas restauré : les torrents reviennent
  par le dossier `watch`, comme des nouveaux. Transmission les vérifie contre
  les fichiers présents : complets si les téléchargements ont été recopiés,
  à zéro sinon. Recopiez donc les téléchargements avant de restaurer, dans
  les sous-dossiers du dossier des données (`complete`, `incomplete`,
  `watch`, `documents`) : un dossier qui contient autre chose est refusé.
- Une sauvegarde hebdomadaire en échec, ou absente depuis plus de 8 jours,
  n'est signalée qu'à la connexion SSH et par `seedtunnel doctor` : aucun
  courriel.
