#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
clang -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 \
    -DRADIO_FAMILY_TESTING -DTX500_TEST_SECRET_STORE -IHeaders -framework Cocoa -framework Security \
    tests/RadioFamilySupportTests.m Sources/RadioFamilySupport.m -o build/RadioFamilySupportTests
RADIO_FAMILY_TEMP=$(mktemp -d /tmp/Lab599RadioFamily.XXXXXX)
trap 'rm -rf "$RADIO_FAMILY_TEMP"' EXIT
RADIO_FAMILY_TEST_ROOT="$RADIO_FAMILY_TEMP" ./build/RadioFamilySupportTests
