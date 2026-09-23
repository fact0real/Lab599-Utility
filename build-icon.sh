#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")"

# Regenerate the approved Obsidian Signal icon. The former firmware-updater
# artwork remains in assets/branding/legacy-firmware-updater-2.173/.
SOURCE_PNG="assets/branding/obsidian-signal/Lab599-Utility-Obsidian-Final.png"
test -s "$SOURCE_PNG" || { echo "Missing icon master: $SOURCE_PNG" >&2; exit 1; }
mkdir -p build/AppIcon.iconset
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE_PNG" \
        --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SOURCE_PNG" \
        --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o assets/AppIcon.icns
cp assets/AppIcon.icns Resources/AppIcon.icns
cp build/AppIcon.iconset/icon_512x512@2x.png assets/AppIcon.png
echo "Generated assets/AppIcon.icns, Resources/AppIcon.icns and the 1024-pixel PNG preview."
