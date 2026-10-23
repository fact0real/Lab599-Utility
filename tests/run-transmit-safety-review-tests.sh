#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build validation
sh tests/run-station-tests.sh
sh tests/run-cw-transmit-safety-tests.sh
sh tests/run-voice-keyer-tests.sh
sh tests/run-digital-controls-tests.sh
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 \
 -framework Cocoa -framework UniformTypeIdentifiers -IHeaders -ISources \
 tests/ScreenCaptureTests.m Sources/TX500ScreenModel.m Sources/TX500ScreenRenderer.m \
 Sources/TX500ScreenCaptureController.m Sources/TX500CATTest.m Sources/Lab599SerialPort.m -o build/ScreenCaptureTests
./build/ScreenCaptureTests
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 \
 -framework Cocoa -framework UniformTypeIdentifiers -IHeaders -ISources \
 tests/SettingsEditorTests.m Sources/Lab599ToolsController.m Sources/TX500CATTest.m Sources/TX500Configuration.m \
 Sources/TX500Transfer.m Sources/TX500ProfilesAndBackup.m Sources/TX500SettingsModel.m Sources/Lab599SerialPort.m -o build/SettingsEditorTests
lab_review_preferences=$(mktemp -d /tmp/Lab599TransmitReview.XXXXXX)
trap 'rm -rf "$lab_review_preferences"' EXIT
CFFIXED_USER_HOME="$lab_review_preferences" ./build/SettingsEditorTests
clang -O1 -g -Wall -Wextra -Werror -fobjc-arc -mmacosx-version-min=12.0 -framework Cocoa \
 -ISources tests/TransmitSafetyNoticeUITests.m -o build/TransmitSafetyNoticeUITests
./build/TransmitSafetyNoticeUITests
