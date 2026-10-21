#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
ICON_TARGET="${1:-$PROJECT_ROOT/Resources/AudioChain.icns}"
ICON_TEMP="$(mktemp -d "${TMPDIR:-/private/tmp}/AudioChainIcon.XXXXXX")"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICON_SET="$ICON_TEMP/AudioChain.iconset"
mkdir -p "$ICON_SET"
for side in 16 32 128 256 512; do
    sips -z "$side" "$side" "$PROJECT_ROOT/Resources/AudioChainIcon.png" --out "$ICON_SET/icon_${side}x${side}.png" >/dev/null
    retina_side=$((side * 2))
    sips -z "$retina_side" "$retina_side" "$PROJECT_ROOT/Resources/AudioChainIcon.png" --out "$ICON_SET/icon_${side}x${side}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o "$ICON_TARGET"
