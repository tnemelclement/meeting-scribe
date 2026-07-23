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

Au premier lancement, macOS demandera deux permissions au terminal : **Micro** et **Enregistrement de l'audio système**.

## Usage

```sh
./scribe                          # enregistre, Ctrl-C pour arrêter → transcrit → écrit le .md
./scribe --title standup          # nom de la note
./scribe --lang auto              # langue (défaut : fr)
./scribe --model tiny             # modèle whisper (défaut : large-v3-turbo, téléchargé au 1er usage)
./scribe --redo <dossier>         # re-transcrit une session déjà enregistrée
```

Variables d'environnement :

| Variable | Défaut | Rôle |
|---|---|---|
| `SCRIBE_OUT` | `0_INBOX` du vault Obsidian | dossier de sortie du markdown |
| `SCRIBE_SESSIONS` | `~/Music/scribe` | dossier des enregistrements WAV |

## Comment ça marche

1. `syscap` (Swift) crée un Core Audio Process Tap global + un aggregate device privé, et enregistre deux WAV : `system.wav` (sortie audio = les autres) et `mic.wav` (vous). Pas de driver, pas de BlackHole.
2. `scribe` (Python, stdlib uniquement) resample en 16 kHz mono avec `afconvert` (fourni par macOS), transcrit les deux pistes avec `whisper-cli`, fusionne les segments par timestamp et écrit le markdown.

## Limites connues

- Diarisation à 2 canaux seulement : « Moi » vs « Eux » (les participants distants sont mixés dans l'audio système). C'est le compromis de l'approche sans bot — même limite que Granola.
- Pas de détection automatique de réunion : lancement manuel.
- ⚠️ **Légal** : en France, enregistrer une conversation sans le consentement des participants est interdit (art. 226-1 du Code pénal, RGPD). Prévenez vos interlocuteurs.

## Licence

MIT
