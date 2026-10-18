#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
    clang -O2 -Wall -Wextra -Wno-unused-parameter -Werror -fobjc-arc \
        -mmacosx-version-min=12.0 -framework Cocoa -framework UniformTypeIdentifiers -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework WebKit -framework Security -lsqlite3 \
        -DTX500_TEST_SECRET_STORE -IHeaders -ISources -IHeaders/cft8 -ISources/cft8 \
        tests/LogbookAndCloudTests.m Sources/TX500LogbookManager.m Sources/TX500LogbookController.m Sources/TX500CallsignLookupService.m Sources/TX500CloudSyncEngine.m \
        Sources/TX500FT8AutoEngine.m Sources/TX500CWQSOAssistant.m Sources/TX500FT8Message.m Sources/TX500FT8AudioEngine.m Sources/TX500TimeDiscipline.m \
        Sources/TX500WebAuthenticatorController.m Sources/TX500CloudSettingsController.m \
        Sources/cft8/ft8/constants.c Sources/cft8/ft8/crc.c Sources/cft8/ft8/encode.c Sources/cft8/ft8/decode.c Sources/cft8/ft8/ldpc.c Sources/cft8/ft8/message.c Sources/cft8/ft8/text.c Sources/cft8/fft/kiss_fft.c Sources/cft8/fft/kiss_fftr.c Sources/cft8/common/wave.c Sources/cft8/common/monitor.c Sources/cft8/shim/tx500_ft8_shim.c \
        -o build/LogbookAndCloudTests
TEST_PREFS_ROOT=$(mktemp -d /tmp/Lab599CloudPreferences.XXXXXX)
trap 'rm -rf "$TEST_PREFS_ROOT"' EXIT
CFFIXED_USER_HOME="$TEST_PREFS_ROOT" ./build/LogbookAndCloudTests
