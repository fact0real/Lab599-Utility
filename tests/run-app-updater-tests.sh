#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/prepare-sparkle.sh
mkdir -p build
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-nonnull -fobjc-arc -mmacosx-version-min=12.0 \
    -framework Cocoa -FVendor/Sparkle -framework Sparkle -Wl,-rpath,"$PWD/Vendor/Sparkle" \
    -IHeaders tests/AppUpdaterTests.m Sources/Lab599AppUpdater.m -o build/AppUpdaterTests
TEST_PREFS_ROOT=$(mktemp -d /tmp/Lab599UpdaterPreferences.XXXXXX)
trap 'rm -rf "$TEST_PREFS_ROOT"' EXIT
TEST_APP="$TEST_PREFS_ROOT/UpdaterHarness.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Frameworks"
cp build/AppUpdaterTests "$TEST_APP/Contents/MacOS/UpdaterHarness"
cp Resources/Info.plist "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable UpdaterHarness' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier ir.factoreal.lab599-updater-tests' "$TEST_APP/Contents/Info.plist"
ditto Vendor/Sparkle/Sparkle.framework "$TEST_APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$TEST_APP"
CFFIXED_USER_HOME="$TEST_PREFS_ROOT" "$TEST_APP/Contents/MacOS/UpdaterHarness"
