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

Au premier lancement, macOS demande deux permissions **au terminal depuis lequel vous lancez la commande** : *Microphone* et *Enregistrement audio*.

⚠️ Piège important : quand la permission d'enregistrement audio manque, macOS **ne renvoie pas d'erreur** — le tap livre du silence, et vous obtenez un fichier de la bonne durée entièrement vide. Le VU-mètre affiché pendant l'enregistrement sert justement à repérer ça immédiatement, et `syscap` prévient à l'arrêt si une piste est restée muette.

Lancez le premier enregistrement depuis un terminal interactif (Terminal.app, iTerm) pour que le prompt puisse s'afficher. Si aucun prompt n'apparaît, ajoutez votre terminal à la main :

```sh
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
```

## Usage

Pendant l'enregistrement, un VU-mètre confirme que les deux pistes captent :

```
  02:34   Moi ███████·············   Eux ██████████··········
```

```sh
./scribe                          # enregistre, Ctrl-C pour arrêter → transcrit → écrit le .md
./scribe --title standup          # nom de la note
./scribe --lang auto              # langue (défaut : fr)
./scribe --backend local          # moteur : local | api | ask (défaut : demande à l'arrêt)
./scribe --model tiny             # modèle whisper local (défaut : large-v3-turbo, téléchargé au 1er usage)
./scribe --redo <dossier>         # re-transcrit une session déjà enregistrée
```

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

1. `syscap` (Swift) crée un Core Audio Process Tap global + un aggregate device privé, et enregistre deux WAV : `system.wav` (sortie audio = les autres) et `mic.wav` (vous). Pas de driver, pas de BlackHole.
2. `scribe` (Python, stdlib uniquement) resample en 16 kHz mono avec `afconvert` (fourni par macOS), transcrit les deux pistes avec le moteur choisi (whisper.cpp local, ou l'API OpenAI via le CLI [whisper-cli](https://github.com/tnemelclement/whisper-cli)), fusionne les segments par timestamp et écrit le markdown.

## Limites connues

- Diarisation à 2 canaux seulement : « Moi » vs « Eux » (les participants distants sont mixés dans l'audio système). C'est le compromis de l'approche sans bot — même limite que Granola.
- Pas de détection automatique de réunion : lancement manuel.
- ⚠️ **Légal** : en France, enregistrer une conversation sans le consentement des participants est interdit (art. 226-1 du Code pénal, RGPD). Prévenez vos interlocuteurs.

## Licence

MIT
