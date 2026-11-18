# Services tiers

Les services extérieurs que le serveur contacte, ce qu'ils reçoivent, et
quand. SeedTunnel n'envoie aucune statistique et ne contacte rien d'autre.
Chacun de ces services voit l'adresse IP publique du serveur.

|Service|Quand|Ce qui est envoyé|Pourquoi|
|-|-|-|-|
|Dépôts Debian (miroirs APT)|Installations, `unattended-upgrades` chaque jour|Requêtes APT habituelles|Paquets et mises à jour de sécurité.|
|`api.github.com`, `github.com` et ses serveurs de fichiers|`seedtunnel update` seulement, jamais en arrière-plan|Lecture de la liste des versions publiées, téléchargement de l'archive, de `SHA256SUMS` et de sa signature|Mise à jour signée (voir [mise à jour](mise-a-jour.md)).|
|`api.ipify.org`, puis `ifconfig.me`, puis `ipv4.icanhazip.com`|Installation du VPN sans adresse donnée, installation de la seedbox, changement de domaine, `seedtunnel doctor`|Une requête HTTPS sans donnée ; le premier qui répond suffit|Connaître l'adresse publique du serveur, qui peut être derrière une traduction d'adresses (NAT). Sans réponse : l'adresse de la route par défaut.|
|DNS Quad9 (`9.9.9.9`)|Installation de la seedbox, changement de domaine, `seedtunnel doctor`|Le nom de domaine du serveur (requête A), ou son adresse (requête inverse, pour proposer le nom donné par l'hébergeur)|Vérifier que le domaine pointe bien vers le serveur.|
|Let's Encrypt (`acme-v02.api.letsencrypt.org`, ou les serveurs de test avec `--staging`)|Installation de la seedbox, changement de domaine, renouvellement automatique (`certbot.timer`)|Le nom de domaine, sans adresse électronique ; validation par le port 80|Certificat HTTPS.|
|`portcheck.transmissionbt.com`|`seedtunnel doctor`, seedbox installée et Transmission actif|Le numéro du port BitTorrent ; le service se connecte au serveur sur ce port|Savoir si le port BitTorrent est joignable depuis Internet. Sans réponse : non testé, sans alerte.|

## DNS des clients VPN

Les appareils connectés au VPN envoient leurs requêtes DNS au service choisi
(`seedtunnel vpn dns`) : Quad9 par défaut (`9.9.9.9`, `149.112.112.112`),
Cloudflare, DNS4EU, AdGuard, ou les adresses de votre choix. C'est ce
service, et non le serveur, qui voit les noms consultés par les appareils.

## Ce qui ne sort pas

- Le rapport de `seedtunnel doctor --link` est servi par le serveur
  lui-même, par un lien à usage unique : il n'est déposé chez aucun service.
- Les liens de téléchargement (fichiers des clients, profils SFTP,
  sauvegardes) sont servis par le serveur lui-même.
- Les tests de `seedtunnel doctor` sur le site HTTPS passent par l'adresse
  publique du serveur, sans service tiers.
