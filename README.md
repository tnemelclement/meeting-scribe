# meeting-scribe

Transcription de réunions **100 % locale** sur macOS, sans bot dans la réunion.

Capture l'audio système (les autres participants) et le micro (vous) sur deux pistes séparées via les Core Audio Process Taps, transcrit localement avec [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (Metal), et écrit un markdown horodaté avec attribution « Moi / Eux » — prêt à être traité par un LLM ou rangé dans Obsidian.

Fonctionne avec n'importe quelle plateforme (Zoom, Meet, Teams, Discord…) puisque la capture se fait au niveau de l'OS. Rien ne quitte votre machine.

## Prérequis

- macOS 14.4+ (Apple Silicon recommandé)
- Xcode Command Line Tools
- `brew install whisper-cpp`

## Installation

```sh
git clone git@github.com:tnemelclement/meeting-scribe.git
cd meeting-scribe
swift build -c release
```

### Permissions (à faire une fois)

`syscap` a besoin de deux permissions, accordées **au terminal depuis lequel vous lancez la commande** :

- **Microphone** — pour votre voix (piste « Moi »).
- **Enregistrement de l'écran et de l'audio système** — pour l'audio des autres participants (piste « Eux »). C'est [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) qui capte le son système ; la permission est la même que pour une capture d'écran.

Au premier lancement, macOS affiche le prompt d'enregistrement d'écran. Si la permission est refusée ou absente, `syscap` s'arrête immédiatement avec les étapes à suivre (il n'enregistre jamais du silence en douce). Pour l'accorder à la main :

```sh
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Cochez votre terminal (Terminal, iTerm…), **quittez-le et relancez-le**, puis réessayez. Le VU-mètre pendant l'enregistrement confirme que les deux pistes captent.

## Usage

Dans un terminal, `scribe` affiche une **interface plein écran** (curses, sans dépendance) :

- **Enregistrement** : horloge, indicateur `● REC`, et deux VU-mètres (Moi / Eux) qui confirment en direct que les pistes captent. On arrête avec `s` (ou Ctrl-C).
- **Transcription** : choix du moteur (local / API) puis deux barres de progression.

L'interface se désactive avec `--no-ui`, ou automatiquement quand la sortie est redirigée (on retombe alors sur un affichage ligne par ligne).

```sh
./scribe                          # enregistre, Ctrl-C pour arrêter → transcrit → écrit le .md
./scribe --title standup          # nom de la note
./scribe --lang auto              # langue (défaut : fr)
./scribe --backend local          # moteur : local | api | ask (défaut : demande à l'arrêt)
./scribe --model tiny             # modèle whisper local (défaut : large-v3-turbo, téléchargé au 1er usage)
./scribe --list                   # liste les anciens enregistrements (date, durée, transcrit ou non)
./scribe --redo 2                 # re-transcrit l'enregistrement n°2 de la liste
./scribe --redo last              # re-transcrit le dernier enregistrement
./scribe --redo <dossier>         # …ou par chemin
./scribe --no-ui                  # désactive l'interface plein écran
```

Les enregistrements sont conservés dans `~/Music/scribe/` (configurable via `SCRIBE_SESSIONS`). `--list` affiche leur date, durée, et s'ils ont déjà été transcrits ; `--redo` en re-transcrit un par numéro, par `last`, ou par chemin — pratique pour re-jouer un enregistrement avec l'autre moteur (local ↔ API) ou après une amélioration du pipeline.

### Choix du moteur de transcription

À l'arrêt de l'enregistrement, `scribe` demande comment transcrire (sauf si `--backend` est passé) :

- **local** — [whisper.cpp](https://github.com/ggerganov/whisper.cpp) sur le GPU Metal, modèle `large-v3-turbo`. Gratuit, hors-ligne, privé. ~20-30× temps réel sur Apple Silicon. **Recommandé.**
- **api** — API Whisper d'OpenAI (`whisper-1`). Un peu plus précis sur certains audios, mais ~0,72 $/h de réunion (deux pistes) et l'audio quitte la machine. La clé est lue depuis `OPENAI_API_KEY` ou `~/dev/whisper-cli/.env`.

Une barre de progression suit l'avancement des deux pistes (« Eux » puis « Moi ») :

```
  Moi [███████████████···············]  52%
```

Variables d'environnement :

| Variable | Défaut | Rôle |
|---|---|---|
| `SCRIBE_OUT` | `0_INBOX` du vault Obsidian | dossier de sortie du markdown |
| `SCRIBE_SESSIONS` | `~/Music/scribe` | dossier des enregistrements WAV |

## Comment ça marche

1. `syscap` (Swift) capte l'audio système via ScreenCaptureKit (16 kHz mono) et le micro via AVAudioEngine, et enregistre deux WAV : `system.wav` (les autres) et `mic.wav` (vous). Pas de driver, pas de BlackHole, pas de bot dans la réunion.
2. `scribe` (Python, stdlib uniquement) resample en 16 kHz mono avec `afconvert` (fourni par macOS), transcrit les deux pistes avec le moteur choisi (whisper.cpp local, ou l'API OpenAI via le CLI [whisper-cli](https://github.com/tnemelclement/whisper-cli)), fusionne les segments par timestamp et écrit le markdown.

## Limites connues

- Diarisation à 2 canaux seulement : « Moi » vs « Eux » (les participants distants sont mixés dans l'audio système). C'est le compromis de l'approche sans bot — même limite que Granola.
- Pas de détection automatique de réunion : lancement manuel.
- ⚠️ **Légal** : en France, enregistrer une conversation sans le consentement des participants est interdit (art. 226-1 du Code pénal, RGPD). Prévenez vos interlocuteurs.

## Licence

MIT
