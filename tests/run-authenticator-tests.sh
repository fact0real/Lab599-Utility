#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build validation
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 \
 -framework Cocoa -framework WebKit -framework Security -framework UniformTypeIdentifiers -lsqlite3 \
 -IHeaders -ISources -IHeaders/cft8 -ISources/cft8 \
 tests/AuthenticatorTests.m Sources/TX500WebAuthenticatorController.m Sources/TX500CloudSettingsController.m \
 Sources/TX500CloudSyncEngine.m Sources/TX500LogbookManager.m -o build/AuthenticatorTests
if [ "${1:-}" = "--build-only" ]; then exit 0; fi
TEST_ROOT=$(mktemp -d /tmp/Lab599AuthenticatorTests.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
CFFIXED_USER_HOME="$TEST_ROOT" TX500_TEST_ROOT="$TEST_ROOT" TX500_TEST_MODE=1 ./build/AuthenticatorTests
