#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 \
    -DTX500_TEST_SECRET_STORE -framework Cocoa -framework UniformTypeIdentifiers -framework AVFoundation \
    -framework CoreAudio -framework AudioToolbox -framework WebKit -framework Security -lsqlite3 \
    -IHeaders -ISources -IHeaders/cft8 -ISources/cft8 tests/MediaGallerySafetyTests.m \
    Sources/TX500SSTVStationController.m Sources/TX500SSTVEngine.m Sources/TX500SSTVOptionNotes.m \
    Sources/TX500SSTVLogDraft.m Sources/TX500SSTVRecordingStore.m Sources/TX500FaxEngine.m \
    Sources/TX500FaxStationController.m Sources/TX500LogbookManager.m Sources/TX500CloudSyncEngine.m \
    Sources/TX500CallsignLookupService.m Sources/TX500WebAuthenticatorController.m \
    Sources/sstv1/sstv_rx.c Sources/sstv1/wefax_rx.c Sources/sstv1/demod.c Sources/sstv1/modes.c Sources/sstv1/wav.c \
    -o build/MediaGallerySafetyTests
./build/MediaGallerySafetyTests "$@"
