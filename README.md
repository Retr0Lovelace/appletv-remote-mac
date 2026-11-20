# Télécommande Apple TV pour macOS

Une télécommande Apple TV virtuelle pour Mac, au look de la Siri Remote en aluminium.
L'app est écrite en SwiftUI natif. Le protocole Apple (Companion / AirPlay, appairage HAP) est délégué à
[pyatv](https://pyatv.dev).

<p align="center">
  <img src="docs/telecommande.png" width="260" alt="La télécommande">
  &nbsp;&nbsp;
  <img src="docs/applications.png" width="260" alt="Toutes les applications">
</p>

## Fonctionnalités

- **Pavé tactile** comme sur la Siri Remote :
  - glisser = swipe ;
  - clic au centre = OK, appui long = OK long ;
  - clic sur l'anneau = flèche ;
  - défilement à deux doigts sur le trackpad = swipe.
- **Boutons** : Retour, TV/Accueil (appui long : Centre de contrôle), Lecture/Pause, Muet, Volume ±, ⏻ veille/allumage.
- **Applications installées** sur l'Apple TV, sous forme de boutons ronds avec le logo de l'app en noir et blanc.
  Les logos viennent de l'App Store, et les apps Apple utilisent une icône système. Les favoris
  (Netflix, YouTube, Prime Video…) passent en premier.
- **En cours de lecture** : pochette, titre et progression, avec ⏮ ⏯ ⏭. L'écran n'apparaît que pendant une lecture.
- **Envoi de texte** vers le clavier de l'Apple TV, pour la recherche ou les identifiants. Le champ s'allume quand un clavier est actif sur la TV.
- **Raccourcis clavier** (inactifs dans le champ texte) :

  | Touche | Action |
  |---|---|
  | Flèches | Navigation |
  | Entrée | OK |
  | Échap / ⌫ | Retour |
  | H | Accueil |
  | Espace | Lecture/Pause |
  | + / − | Volume |

- **Fenêtre transparente** : seule la télécommande flotte sur le bureau. On la déplace en la tirant par l'aluminium.
  Clic droit = réglages, appairage, quitter.
- **Icône dans la barre des menus** : lecture/pause, volume, muet, veille.
- **Plusieurs Apple TV** : un clic sur le nom en bas de la télécommande permet de changer d'appareil.

## Prérequis

- macOS 15 ou plus récent, sur Apple Silicon.
- **Xcode** installé. Les Command Line Tools seules ne fournissent pas le plugin de macros SwiftUI que `build.sh` utilise.
- [uv](https://docs.astral.sh/uv/). `setup.sh` l'installe dans `~/.local/bin` s'il est absent.

## Installation

```bash
git clone https://github.com/Retr0Lovelace/appletv-remote-mac.git ~/AppleTVRemote
cd ~/AppleTVRemote
./setup.sh   # crée .venv (Python 3.12) et installe pyatv
./build.sh   # compile build/Télécommande Apple TV.app (swiftc, sans projet Xcode)
open "build/Télécommande Apple TV.app"
```

L'app lance l'assistant Python depuis le dossier du projet. Laisse-la dans `build/`, ou clone le projet dans
`~/AppleTVRemote`, qui est le dossier utilisé par défaut.

Au premier lancement, autorise l'accès au **Réseau local** quand macOS le demande
(Réglages Système → Confidentialité et sécurité → Réseau local).

## Appairage

<img src="docs/appairage.png" width="360" alt="Appairage" align="right">

1. Clic droit sur la télécommande → **Appairer…**, puis choisis l'Apple TV.
2. **Étape 1/2 (Companion)** : tape le code à 4 chiffres affiché sur la TV.
3. **Étape 2/2 (AirPlay)** : tape le second code. Cette étape sert à l'affichage de la lecture en cours.

Les identifiants sont enregistrés dans `pyatv.conf`, à la racine du projet. Ce fichier est ignoré par git :
il contient des clés privées, ne le partage pas.

Si l'appairage est indiqué « désactivé », va sur l'Apple TV dans Réglages → AirPlay et HomeKit →
Autoriser l'accès, et choisis « Toute personne sur le même réseau ».

<br clear="right">

## Architecture

```
Sources/            app SwiftUI (Swift 6, concurrence stricte)
  ATVController     état de la télécommande (@MainActor @Observable)
  HelperClient      lance l'assistant Python et dialogue en JSON lignes (stdin/stdout)
  RemoteParts       corps aluminium, pavé tactile, boutons, voyant
  IconStore         logos via l'API iTunes, cache disque, conversion en noir et blanc
helper/atv_helper.py   assistant asyncio autour de pyatv (scan, appairage, touches, swipe, texte, apps…)
```

Test manuel de l'assistant :

```bash
echo '{"id":1,"cmd":"scan","args":{}}' | .venv/bin/python helper/atv_helper.py
```

Les captures de ce README sont générées par l'app elle-même (aucune autorisation d'écran nécessaire) :

```bash
"build/Télécommande Apple TV.app/Contents/MacOS/AppleTVRemote" --snapshot docs/
# variables d'environnement facultatives : SNAPSHOT_EXPAND_APPS=1, SNAPSHOT_PAIRING=1, SNAPSHOT_DELAY=10
```

## Notes

- `srptools` est bloqué sous la version 2, car la 2.0 casse l'appairage de pyatv 0.18.
- Le bouton **Muet** passe par le réglage du volume. Il n'est actif que si l'appareil branché à l'Apple TV
  accepte le contrôle du volume.

## Licence

MIT. Projet personnel, non affilié à Apple. « Apple TV » et « Siri Remote » sont des marques d'Apple Inc.
