#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/power-review
clang -O1 -g -Wall -Wextra -Wno-unused-parameter -Werror -fobjc-arc \
    -mmacosx-version-min=12.0 -framework Cocoa -framework UniformTypeIdentifiers \
    -IHeaders -ISources tests/PowerCalibrationTests.m Sources/TX500PowerCalibration.m \
    Sources/TX500PowerCalibrationController.m Sources/Lab599TelemetryController.m \
    Sources/TX500TelemetryEngine.m Sources/Lab599SerialPort.m Sources/TXGaugeView.m -o build/PowerCalibrationTests
./build/PowerCalibrationTests "$@"
