#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
for suite in CWAudioSelectionTests CWStationTests; do
    clang -O2 -Wall -Wextra -Wno-unused-parameter -Werror -fobjc-arc \
        -mmacosx-version-min=12.0 -framework Cocoa -framework UniformTypeIdentifiers \
        -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework WebKit -framework Security -lsqlite3 \
        -IHeaders -ISources -IHeaders/cft8 -ISources/cft8 \
        "tests/$suite.m" Sources/TX500CWAudioDecoder.m Sources/TX500CWKeyer.m Sources/TX500CWQSOAssistant.m \
        Sources/TX500CWSpectrumView.m Sources/TX500CWStationController.m Sources/TX500LogbookManager.m \
        Sources/TX500CallsignLookupService.m Sources/TX500CloudSyncEngine.m Sources/TX500WebAuthenticatorController.m \
        -o "build/$suite"
done
if [ "${1:-}" = "--build-only" ]; then exit 0; fi
TEST_ROOT=$(mktemp -d /tmp/Lab599CWSelectionTests.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
CFFIXED_USER_HOME="$TEST_ROOT" TX500_TEST_ROOT="$TEST_ROOT" TX500_TEST_MODE=1 ./build/CWAudioSelectionTests
./build/CWStationTests
