# Captures SeedTunnel

Auteur : FinalCut.

Les captures présentent dix écrans en français et en anglais : accueil, VPN,
seedbox, accès, clés SSH, SFTP, politique SSH, protection, maintenance et
sauvegardes. Les données affichées sont fictives.

Le README utilise directement `fr-home.png`.

## État des captures

Les images actuelles ont été produites avec l'aperçu de la version 1.0.0 :
voir `version` et `preview_sha256` dans `manifest.json`. `source_sha` désigne
le commit de préparation qui a servi à les générer, avant la publication ; il
n'est pas publié, mais son `tools/preview.sh` est identique à celui de la
version 1.0.0 (même `preview_sha256`). Il faut régénérer les captures quand
les écrans ou le numéro de version changent.

## Génération

Prérequis : Python 3, Playwright, Chromium et DejaVu Sans Mono.
Le script `capture.py` lance `tools/preview.sh` et génère les images ainsi que
`manifest.json`, qui contient les informations de source et les empreintes.
Il remplace les captures présentes dans ce répertoire.

Depuis la racine du dépôt :

```bash
python3 docs/screens/capture.py --source-dir "$PWD" --source-sha "$(git rev-parse HEAD)"
```
