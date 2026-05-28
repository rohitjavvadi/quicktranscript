#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PYTHON="${PYTHON:-.venv/bin/python}"
SESSION_NAME="meeting-$(date +%Y-%m-%d-%H-%M-%S)"
SESSION_DIR="$HOME/Desktop/MeetingTranscripts/$SESSION_NAME"

if [[ ! -x "$PYTHON" ]]; then
  echo "Creating local Python environment..."
  python3 -m venv .venv
  PYTHON=".venv/bin/python"
fi

if ! "$PYTHON" -c 'import mlx_whisper' >/dev/null 2>&1; then
  echo "mlx-whisper is not installed yet."
  echo "Install it with:"
  echo "  $PYTHON -m pip install mlx-whisper"
  echo ""
  echo "Then run ./start.sh again."
  exit 1
fi

echo "Starting recorder..."
echo "Session folder: $SESSION_DIR"
echo ""
mkdir -p "$SESSION_DIR"

if [[ ! -x ./quick-transcript ]]; then
  echo "Building recorder..."
  mkdir -p .build/module-cache
  CLANG_MODULE_CACHE_PATH=.build/module-cache swiftc QuickTranscript/Sources/QuickTranscript/main.swift -framework AVFoundation -o quick-transcript
fi

"$PYTHON" scripts/transcribe_watch.py "$SESSION_DIR" &
WATCHER_PID="$!"

cleanup() {
  kill "$WATCHER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

QUICK_TRANSCRIPT_SESSION_DIR="$SESSION_DIR" ./quick-transcript

echo ""
echo "Catching up any final audio chunks..."
cleanup
"$PYTHON" scripts/transcribe_watch.py "$SESSION_DIR" --once

echo ""
echo "Transcript file:"
echo "  $SESSION_DIR/transcript.txt"
