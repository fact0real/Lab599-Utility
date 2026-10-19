#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
clang -O0 -Wall -Wextra -Wno-unused-parameter -Werror -fobjc-arc \
        -mmacosx-version-min=12.0 -framework UniformTypeIdentifiers -framework Cocoa -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework WebKit -framework Security -lsqlite3 \
        -DTX500_TEST_SECRET_STORE -IHeaders -ISources -IHeaders/cft8 -ISources/cft8 \
        tests/DigitalControlsTests.m Sources/TX500FT8StationController.m Sources/TX500FT8WaterfallView.m Sources/TX500PSKReporter.m Sources/TX500FT8Message.m Sources/TX500FT8AudioEngine.m Sources/TX500FT8AutoEngine.m Sources/TX500TimeDiscipline.m \
        Sources/TX500LogbookManager.m Sources/TX500CallsignLookupService.m Sources/TX500CloudSyncEngine.m Sources/TX500WebAuthenticatorController.m \
        Sources/cft8/ft8/constants.c Sources/cft8/ft8/crc.c Sources/cft8/ft8/encode.c Sources/cft8/ft8/decode.c Sources/cft8/ft8/ldpc.c Sources/cft8/ft8/message.c Sources/cft8/ft8/text.c Sources/cft8/fft/kiss_fft.c Sources/cft8/fft/kiss_fftr.c Sources/cft8/common/wave.c Sources/cft8/common/monitor.c Sources/cft8/shim/tx500_ft8_shim.c \
        -o build/DigitalControlsTests
TEST_ROOT=$(mktemp -d /tmp/Lab599DigitalControls.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
TX500_TEST_ROOT="$TEST_ROOT" CFFIXED_USER_HOME="$TEST_ROOT" ./build/DigitalControlsTests
