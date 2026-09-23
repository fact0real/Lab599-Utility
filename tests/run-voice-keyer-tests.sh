#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build validation
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc \
    -mmacosx-version-min=12.0 -framework Cocoa -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework UniformTypeIdentifiers \
    -IHeaders -ISources tests/VoiceKeyerTests.m Sources/TX500VoiceKeyer.m Sources/TX500VoiceCATRadio.m Sources/TX500VoiceAudio.m Sources/TX500VoiceLibrary.m Sources/TX500VoiceKeyerController.m Sources/Lab599SerialPort.m \
    -o build/VoiceKeyerTests
./build/VoiceKeyerTests "$@"
