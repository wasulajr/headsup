#!/usr/bin/env bash
# build-icon.sh — Turn a 1024×1024 PNG into an AppIcon.icns for the
# notifier .app bundle. Run this whenever the designer hands you a new
# source icon. setup.sh re-invokes it automatically on install.
#
# Usage: ./build-icon.sh path/to/source.png
#        (defaults to ./icon-source.png if no arg given)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${1:-$SCRIPT_DIR/icon-source.png}"
OUT="$SCRIPT_DIR/AppIcon.icns"

if [ ! -f "$SOURCE" ]; then
    echo "ERROR: source PNG not found: $SOURCE" >&2
    echo "Drop a 1024×1024 PNG at $SCRIPT_DIR/icon-source.png (or pass one as \$1)" >&2
    exit 1
fi

dim=$(sips -g pixelWidth -g pixelHeight "$SOURCE" 2>/dev/null | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w"x"h}')
if [ "$dim" != "1024x1024" ]; then
    echo "WARNING: source is $dim, expected 1024x1024. Continuing — sips will scale, but image quality may suffer." >&2
fi

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"

# All ten sizes Apple's iconutil wants — 16/32/128/256/512 at 1x and 2x.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    sips -z "$((size * 2))" "$((size * 2))" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
done

iconutil -c icns -o "$OUT" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"
echo "Wrote $OUT"
