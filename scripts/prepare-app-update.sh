#!/bin/sh
# Prepare reviewable signed artifacts only. This script never uploads/publishes.
set -eu
cd "$(dirname "$0")/.."
APP_PATH=${1:-"Lab599 Utility.app"}
NOTES_PATH=${2:-"RELEASE-NOTES-2.286.md"}
sh scripts/prepare-sparkle.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
case "$VERSION" in ''|*[!0-9.]*) echo 'Invalid application version' >&2; exit 1;; esac
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
[ "$BUNDLE_ID" = ir.factoreal.lab599-utility ] || { echo 'Wrong application bundle' >&2; exit 1; }
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PATH/Contents/Info.plist")
SIGNING_PUBLIC_KEY=$(Vendor/Sparkle/bin/generate_keys --account ir.factoreal.lab599-utility.updates -p)
[ "$PUBLIC_KEY" = "$SIGNING_PUBLIC_KEY" ] || { echo 'Signing key does not match the application' >&2; exit 1; }
codesign --verify --deep --strict "$APP_PATH"
test -s "$NOTES_PATH"
OUTPUT="build/app-update-$VERSION"
[ ! -e "$OUTPUT" ] || { echo "Output already exists: $OUTPUT. Preserve it and choose a new build/version." >&2; exit 1; }
mkdir -p "$OUTPUT"
ARCHIVE="Lab599-Utility-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT/$ARCHIVE"
cp "$NOTES_PATH" "$OUTPUT/${ARCHIVE%.zip}.md"
cp updates/appcast.xml "$OUTPUT/appcast.xml"
Vendor/Sparkle/bin/generate_appcast --account ir.factoreal.lab599-utility.updates \
    --download-url-prefix "https://github.com/fact0real/Lab599-Utility/releases/download/$VERSION/" \
    --embed-release-notes --maximum-deltas 0 "$OUTPUT"
Vendor/Sparkle/bin/sign_update --account ir.factoreal.lab599-utility.updates --verify "$OUTPUT/appcast.xml"
(cd "$OUTPUT" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
printf 'Signed review artifacts: %s\nNo files have been published.\n' "$OUTPUT"
