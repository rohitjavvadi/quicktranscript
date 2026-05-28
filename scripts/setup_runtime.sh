#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/QuickTranscript"
VENV="$APP_SUPPORT/.venv"

mkdir -p "$APP_SUPPORT"

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi

"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install mlx-whisper

echo "QuickTranscript runtime installed at:"
echo "$VENV"
