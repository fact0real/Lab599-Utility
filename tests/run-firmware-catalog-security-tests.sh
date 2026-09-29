#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")/.."
mkdir -p build
clang -O2 -Wall -Wextra -Wno-unused-parameter -Werror -fobjc-arc \
    -mmacosx-version-min=12.0 -framework Foundation -IHeaders -ISources \
    tests/FirmwareCatalogSecurityTests.m Sources/Lab599FirmwareCatalog.m Sources/TX500Transfer.m \
    -o build/FirmwareCatalogSecurityTests
./build/FirmwareCatalogSecurityTests
