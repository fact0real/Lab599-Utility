#!/bin/sh
# Official upstream distribution pinned by version and GitHub asset SHA-256.
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD/Vendor/Sparkle"
if [ -f "$ROOT/.lab599-2.10.0" ] && [ -f "$ROOT/Sparkle.framework/Sparkle" ]; then exit 0; fi
ARCHIVE=$(mktemp /tmp/Lab599Sparkle.XXXXXX)
STAGING=$(mktemp -d /tmp/Lab599SparkleStage.XXXXXX)
trap 'rm -f "$ARCHIVE"; rm -rf "$STAGING"' EXIT
curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' --max-time 180 \
    -o "$ARCHIVE" https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
printf '%s  %s\n' c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c "$ARCHIVE" | shasum -a 256 -c -
tar -xJf "$ARCHIVE" -C "$STAGING"
mkdir -p "$ROOT"
/usr/bin/ditto "$STAGING/Sparkle.framework" "$ROOT/Sparkle.framework"
/usr/bin/ditto "$STAGING/bin" "$ROOT/bin"
cp "$STAGING/LICENSE" "$ROOT/LICENSE"
touch "$ROOT/.lab599-2.10.0"
