#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path


def die(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def require_tools() -> None:
    try:
        import mlx_whisper  # noqa: F401
    except ModuleNotFoundError:
        die(
            "mlx-whisper is not installed in this Python environment.\n"
            "Run: python3 -m venv .venv && .venv/bin/python -m pip install mlx-whisper"
        )

    if subprocess.run(["/usr/bin/env", "ffmpeg", "-version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        die("ffmpeg is required but was not found on PATH.")


def transcribe_audio(path: Path, model: str) -> str:
    import mlx_whisper

    wav_path = path.with_suffix(".transcribe.wav")
    cmd = [
        "ffmpeg",
        "-y",
        "-loglevel",
        "error",
        "-i",
        str(path),
        "-ar",
        "16000",
        "-ac",
        "1",
        str(wav_path),
    ]
    subprocess.run(cmd, check=True)

    result = mlx_whisper.transcribe(str(wav_path), path_or_hf_repo=model)
    wav_path.unlink(missing_ok=True)
    return result.get("text", "").strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Watch QuickTranscript chunks and append local Whisper transcript text.")
    parser.add_argument("session_dir", type=Path)
    parser.add_argument("--model", default=os.environ.get("QUICK_TRANSCRIPT_MODEL", "mlx-community/whisper-tiny"))
    parser.add_argument("--poll", type=float, default=2.0)
    parser.add_argument("--once", action="store_true", help="Process currently completed chunks once, then exit.")
    args = parser.parse_args()

    require_tools()

    session_dir = args.session_dir.expanduser().resolve()
    transcript_path = session_dir / "transcript.txt"
    processed_path = session_dir / ".processed"
    processed: set[str] = set()

    if processed_path.exists():
        processed.update(line.strip() for line in processed_path.read_text().splitlines() if line.strip())

    print(f"Watching: {session_dir}")
    print(f"Transcript: {transcript_path}")
    print(f"Model: {args.model}")
    if args.once:
        print("Processing completed chunks once.")
    else:
        print("Leave this running while the recorder is running. Press Ctrl-C after recording stops.")

    while True:
        if args.once:
            caf_names = [path.name for path in sorted(session_dir.glob("chunk-*.caf"))]
        else:
            caf_names = [marker.name.removesuffix(".done") for marker in sorted(session_dir.glob("chunk-*.caf.done"))]

        for caf_name in caf_names:
            if caf_name in processed:
                continue

            caf_path = session_dir / caf_name
            if not caf_path.exists() or caf_path.stat().st_size == 0:
                continue

            print(f"Transcribing {caf_name} ...", flush=True)
            try:
                text = transcribe_audio(caf_path, args.model)
            except Exception as exc:
                print(f"Failed to transcribe {caf_name}: {exc}", file=sys.stderr)
                continue

            if text:
                with transcript_path.open("a", encoding="utf-8") as transcript:
                    transcript.write(f"\n[{caf_name}]\n{text}\n")
                print(text)
            else:
                print(f"No speech detected in {caf_name}.")

            processed.add(caf_name)
            with processed_path.open("a", encoding="utf-8") as processed_file:
                processed_file.write(caf_name + "\n")

        if args.once:
            break

        time.sleep(args.poll)


if __name__ == "__main__":
    raise SystemExit(main())
