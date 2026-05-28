# QuickTranscript v0.1.0

Initial public release.

## Features

- macOS menu bar app with Start/Stop controls.
- Records microphone audio into 30-second chunks.
- Transcribes chunks locally with MLX Whisper.
- Stores transcripts and raw audio under `~/Desktop/MeetingTranscripts`.
- History menu for recent recordings, transcript paths, folders, and basic metadata.
- Terminal fallback for users who prefer `./start.sh`.

## Setup

Before using the app, install the local transcription runtime:

```bash
./scripts/setup_runtime.sh
```

Then open `QuickTranscript.app`.
