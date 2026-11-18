# Mise à jour

## Mettre à jour

```bash
seedtunnel update
```

Ou dans le menu : Diagnostic et maintenance › Mise à jour. Étapes :

1. Lecture des versions publiées sur GitHub. Seules les versions stables,
   au format `X.Y.Z` et à partir de 1.0.0, sont retenues, et la plus récente
   est proposée. Sans version publiée, SeedTunnel indique qu'il est à jour.
2. Téléchargement en HTTPS de `seedtunnel-X.Y.Z.tar.gz`, `SHA256SUMS` et
   `SHA256SUMS.sig`.
3. Vérification de la signature de `SHA256SUMS` par la clé de publication
   écrite dans le code installé, puis de l'empreinte de l'archive. L'archive
   doit aussi déclarer la version annoncée, et sa syntaxe est contrôlée.
4. Extraction contrôlée : ni lien, ni chemin absolu, ni `..` ; fichiers à
   root, en 755/644.
5. Bascule : la nouvelle version prend la place de `/opt/seedtunnel`, puis
   applique la configuration (`seedtunnel apply`). Si cette étape échoue,
   l'ancienne version revient d'elle-même.
6. La version remplacée est gardée dans `/opt/seedtunnel.old` (une seule).

La moindre erreur de vérification annule la mise à jour, sans rien changer.
Outils nécessaires : `curl`, `jq` (installés par SeedTunnel) et
`ssh-keygen` (paquet `openssh-client`).

## Revenir à la version précédente

```bash
seedtunnel update back
```

La version gardée dans `/opt/seedtunnel.old` reprend sa place et réapplique
les mêmes réglages ; si cela échoue, la version récente revient. La version
récente est alors supprimée : `seedtunnel update` la retélécharge.

## Installation par git

Si `/opt/seedtunnel` est un dépôt git, `seedtunnel update` récupère le tag
`vX.Y.Z` de la version choisie depuis `github.com/finalcutgit411/seedtunnel`.
Il vérifie que ce tag est signé par la même clé de publication, puis passe
sur son commit. Le dossier ne doit avoir aucune modification locale. Pour
revenir en arrière :
`git -C /opt/seedtunnel checkout vX.Y.Z` puis `seedtunnel apply`.

## Interruption et coupure de courant

Pendant la bascule (`update` ou `update back`), Ctrl+C et la fermeture de
la session sont ignorés le temps des deux renommages. Une coupure de courant
peut pourtant laisser l'une de ces deux situations. Dans les deux cas,
`/opt/seedtunnel.previous` contient la version d'avant la bascule.

- **`/opt/seedtunnel` absent, `/opt/seedtunnel.previous` présent** : la
  coupure a eu lieu entre les deux renommages. Remettez la version d'avant
  en place :

  ```bash
  mv -T /opt/seedtunnel.previous /opt/seedtunnel
  seedtunnel apply
  ```

- **`/opt/seedtunnel` et `/opt/seedtunnel.previous` présents** : la nouvelle
  version était en place, mais n'avait peut-être pas fini d'appliquer la
  configuration. Lancez `seedtunnel apply`, puis `seedtunnel doctor`. Si tout
  va bien, supprimez la copie : `rm -rf /opt/seedtunnel.previous`. Sinon,
  remettez la version d'avant :

  ```bash
  mv -T /opt/seedtunnel /opt/seedtunnel.failed
  mv -T /opt/seedtunnel.previous /opt/seedtunnel
  seedtunnel apply
  ```

Tant que `/opt/seedtunnel.previous` existe, `seedtunnel update` et
`seedtunnel update back` refusent de démarrer et le signalent. En cas d'échec, les messages donnent les commandes
exactes ; le détail est dans `/var/log/seedtunnel.log`.

## Vérifier une version à la main

L'[installation du README](../README.md#installation) fait les mêmes
vérifications que `seedtunnel update`. Pour une archive déjà téléchargée,
dans le dossier qui contient les trois fichiers :

```bash
echo 'seedtunnel-release namespaces="seedtunnel-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIcibv00gKCrJdL9NYksnXPaA+EWcszD8s5J4wk7X1MM' >allowed_signers
ssh-keygen -Y verify -f allowed_signers -I seedtunnel-release -n seedtunnel-release -s SHA256SUMS.sig <SHA256SUMS
sha256sum -c SHA256SUMS
```

## La clé de publication

- Clé Ed25519 gardée hors ligne par le mainteneur, jamais sur GitHub. Elle
  signe les `SHA256SUMS` de chaque version et chaque tag git.
- Sa clé publique est écrite dans le code (`lib/update.sh`) et dans le
  README. Une installation existante n'utilise que la clé de sa propre
  version : modifier le README ou la page des versions ne suffit pas à lui
  faire accepter une autre archive.
- Une nouvelle clé n'arrive que par une version signée par la clé en place.
  Si la clé était perdue, aucune version ne serait plus acceptée : chaque
  serveur devrait être réinstallé à la main.
- Limite : à la première installation, la clé vient du README, servi par
  GitHub. Pour plus de sûreté, comparez-la avec une copie obtenue par un
  autre chemin.
