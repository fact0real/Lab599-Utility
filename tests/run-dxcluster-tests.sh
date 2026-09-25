#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build validation
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 \
 -framework Cocoa -framework Network -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Security -framework WebKit -framework UniformTypeIdentifiers -lsqlite3 \
 -IHeaders -ISources -IHeaders/cft8 -ISources/cft8 \
 tests/DXClusterTests.m Sources/TX500DXCluster.m Sources/TX500DXClusterController.m \
 Sources/TX500FT8Message.m Sources/TX500LogbookManager.m Sources/TX500CallsignLookupService.m \
 Sources/TX500LogbookController.m Sources/TX500CloudSyncEngine.m Sources/TX500CloudSettingsController.m Sources/TX500WebAuthenticatorController.m \
 Sources/TX500StationCore.m Sources/TX500StationStore.m Sources/TX500VoiceCATRadio.m Sources/TX500VoiceAudio.m Sources/Lab599SerialPort.m \
 -o build/DXClusterTests
./build/DXClusterTests "$@"
