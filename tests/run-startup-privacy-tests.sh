#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
clang -O2 -Wall -Wextra -Wno-unused-parameter -Werror -fobjc-arc \
    -mmacosx-version-min=12.0 -framework Cocoa -IHeaders -ISources \
    tests/StartupPrivacyTests.m Sources/TX500TimeDiscipline.m Sources/TX500FT8Message.m \
    Sources/Lab599DocsController.m Sources/Lab599FirmwareCatalog.m Sources/TX500Transfer.m \
    -o build/StartupPrivacyTests
TEST_PREFS_ROOT=$(mktemp -d /tmp/Lab599StartupPreferences.XXXXXX)
trap 'rm -rf "$TEST_PREFS_ROOT"' EXIT
CFFIXED_USER_HOME="$TEST_PREFS_ROOT" ./build/StartupPrivacyTests
