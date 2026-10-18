#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 \
    -framework Cocoa -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
    -IHeaders -ISources tests/CWTransmitSafetyTests.m Sources/TX500CWKeyer.m -o build/CWTransmitSafetyTests
./build/CWTransmitSafetyTests
