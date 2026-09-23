#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build validation
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 \
 -framework Cocoa -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
 -IHeaders -ISources tests/StationTests.m Sources/TX500StationCore.m Sources/TX500StationStore.m Sources/TX500StationController.m Sources/TX500PSKReporter.m Sources/TX500VoiceCATRadio.m Sources/TX500VoiceAudio.m Sources/Lab599SerialPort.m -o build/StationTests
./build/StationTests "$@"
