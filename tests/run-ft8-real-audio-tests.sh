#!/bin/sh
# Real FT8 recordings from kgoba/ft8_lib (MIT), fetched at a pinned
# commit so the baseline in tests/FT8RealAudioTests.c stays comparable.
set -eu
cd -- "$(dirname -- "$0")/.."

FT8LIB_COMMIT=9fec6ca39886edbf96f4f5e71edc76da5074e871
DATA=build/ft8_lib-data

if [ ! -d "$DATA/.git" ]; then
    if [ -e "$DATA" ]; then
        echo "Refusing unverified FT8 test data at $DATA" >&2
        exit 1
    fi
    mkdir -p "$DATA"
    git -C "$DATA" init -q
    git -C "$DATA" fetch -q --depth 1 https://github.com/kgoba/ft8_lib.git "$FT8LIB_COMMIT"
    git -C "$DATA" checkout -q --detach FETCH_HEAD
fi
test "$(git -C "$DATA" rev-parse HEAD)" = "$FT8LIB_COMMIT"
test -z "$(git -C "$DATA" status --porcelain -- test/wav)"
test -d "$DATA/test/wav/20m_busy"

clang -std=gnu11 -O1 -g -Wall -Wextra -Wno-unused-parameter -Werror -fsanitize=address,undefined \
    -mmacosx-version-min=12.0 -IHeaders/cft8 -ISources/cft8 \
    tests/FT8RealAudioTests.c \
    Sources/cft8/ft8/constants.c Sources/cft8/ft8/crc.c Sources/cft8/ft8/encode.c Sources/cft8/ft8/decode.c Sources/cft8/ft8/ldpc.c Sources/cft8/ft8/message.c Sources/cft8/ft8/text.c Sources/cft8/fft/kiss_fft.c Sources/cft8/fft/kiss_fftr.c Sources/cft8/common/wave.c Sources/cft8/common/monitor.c Sources/cft8/shim/tx500_ft8_shim.c \
    -o build/FT8RealAudioTests
./build/FT8RealAudioTests "$DATA/test/wav" "$DATA/test/wav/20m_busy"
