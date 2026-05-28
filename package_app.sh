#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP="dist/QuickTranscript.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="dist/AppIcon.iconset"

rm -rf "$APP" "$ICONSET"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET" .build/module-cache

python3 - <<'PY'
from pathlib import Path
import struct
import zlib

out = Path("dist/icon-1024.png")
size = 1024
pixels = bytearray()
for y in range(size):
    row = bytearray()
    for x in range(size):
        dx = (x - size / 2) / (size / 2)
        dy = (y - size / 2) / (size / 2)
        r2 = dx * dx + dy * dy
        inside = r2 <= 0.82
        if inside:
            row.extend((28, 134, 238, 255))
        else:
            row.extend((0, 0, 0, 0))
    pixels.extend(b"\x00" + row)

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(pixels), 9))
png += chunk(b"IEND", b"")
out.write_bytes(png)
PY

for icon in \
  icon_16x16.png:16 \
  icon_16x16@2x.png:32 \
  icon_32x32.png:32 \
  icon_32x32@2x.png:64 \
  icon_128x128.png:128 \
  icon_128x128@2x.png:256 \
  icon_256x256.png:256 \
  icon_256x256@2x.png:512 \
  icon_512x512.png:512 \
  icon_512x512@2x.png:1024
do
  name="${icon%%:*}"
  size="${icon##*:}"
  sips -z "$size" "$size" dist/icon-1024.png --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"

CLANG_MODULE_CACHE_PATH=.build/module-cache swiftc \
  MacMenuApp/Sources/QuickTranscriptMenu.swift \
  -framework AppKit \
  -framework AVFoundation \
  -o "$MACOS/QuickTranscript"

cp MacMenuApp/Info.plist "$CONTENTS/Info.plist"
cp scripts/transcribe_watch.py "$RESOURCES/transcribe_watch.py"
cp scripts/setup_runtime.sh "$RESOURCES/setup_runtime.sh"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP" >/dev/null
else
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$APP" >/dev/null
fi

echo "$PWD/$APP"
