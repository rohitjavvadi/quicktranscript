# QuickTranscript

QuickTranscript is a small macOS app for recording meeting audio from your microphone and transcribing it locally with MLX Whisper.

It was built for the pragmatic case: you join a Zoom/Meet call on laptop speakers, start QuickTranscript, and get a transcript saved to disk while the meeting runs.

## What It Does

- Lives in the macOS menu bar.
- Records microphone audio in 30-second chunks.
- Transcribes completed chunks locally with `mlx-whisper`.
- Appends text to `transcript.txt` during the meeting.
- Keeps raw `.caf` audio chunks so a session can be re-transcribed later.
- Shows recent recordings in a History menu.

## Install With Homebrew

```bash
brew tap rohitjavvadi/tap
brew install --cask quicktranscript
```

The cask installs `QuickTranscript.app` and runs the local runtime setup script, so the MLX Whisper dependencies are installed as part of installation.

## Runtime Dependencies

The app uses a local Python/MLX Whisper runtime stored at:

```text
~/Library/Application Support/QuickTranscript/.venv
```

If the runtime is missing, QuickTranscript installs it automatically the first time you start recording. You can also install or repair it manually:

```bash
./scripts/setup_runtime.sh
```

This downloads `mlx-whisper` and its dependencies.

If you installed the app directly, you can also run:

```bash
/Applications/QuickTranscript.app/Contents/Resources/setup_runtime.sh
```

## Build The App

```bash
./package_app.sh
```

The built app is created at:

```text
dist/QuickTranscript.app
```

Install it locally:

```bash
ditto dist/QuickTranscript.app /Applications/QuickTranscript.app
open /Applications/QuickTranscript.app
```

Maintainer release steps are in [RELEASING.md](RELEASING.md).

## Use

1. Join your meeting using laptop speakers.
2. Open QuickTranscript.
3. Click the menu bar icon.
4. Choose `Start Recording`.
5. Choose `Stop Recording` when done.

Output is written to:

```text
~/Desktop/MeetingTranscripts/meeting-YYYY-MM-DD-HH-MM-SS/
```

The main file is:

```text
transcript.txt
```

## Menu Actions

- `Start Recording`
- `Stop Recording`
- `Open Transcript`
- `Open Session Folder`
- `Copy Transcript Path`
- `History`

History shows recent sessions with start time, audio chunk count, transcript size, and quick actions.

## Notes

- QuickTranscript captures the microphone, not privileged system audio.
- For meeting transcription, use laptop speakers so the microphone hears the call audio.
- The default model is `mlx-community/whisper-tiny` for low latency.
- To use another model, set `QUICK_TRANSCRIPT_MODEL` before launching from a shell.

## Terminal Fallback

The original terminal workflow still exists:

```bash
./start.sh
```

## License

MIT
