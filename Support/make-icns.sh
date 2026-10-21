#!/bin/bash
# Turn a 1024×1024 PNG into Support/AppIcon.icns: ./Support/make-icns.sh icon.png
set -euo pipefail
cd "$(dirname "$0")"
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$1" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$1" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "Wrote Support/AppIcon.icns"
