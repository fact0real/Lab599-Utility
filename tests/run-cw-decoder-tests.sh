#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")/.."
mkdir -p build/cw-decoder-tests
if [ "${1:-}" = "--benchmark" ]; then
    clang -O2 -Wall -Wextra -Wno-unused-parameter -Werror -fobjc-arc \
        -mmacosx-version-min=12.0 -framework Foundation -framework AVFoundation \
        -framework CoreAudio -framework AudioToolbox -IHeaders \
        tests/Benchmark200NoisyCW.m Sources/TX500CWAudioDecoder.m \
        -o build/cw-decoder-tests/Benchmark200NoisyCW
    exec build/cw-decoder-tests/Benchmark200NoisyCW --blind
fi
clang -O2 -Wall -Wextra -Wno-unused-parameter -Werror -fobjc-arc \
    -mmacosx-version-min=12.0 -framework Foundation -framework AVFoundation \
    -framework CoreAudio -framework AudioToolbox -IHeaders \
    tests/CWDecoderRegressionTests.m Sources/TX500CWAudioDecoder.m \
    -o build/cw-decoder-tests/CWDecoderRegressionTests
if [ "$#" -gt 0 ]; then
    # Keep the originals untouched. FFmpeg also avoids platform-specific AAC
    # client-format errors from AVAudioFile in command-line test processes.
    command -v ffmpeg >/dev/null
    mkdir -p build/cw-decoder-tests/fixtures
    for number in 3 4 5 6 7 9; do
        ffmpeg -v error -y -i "$1/$number.m4a" -ac 1 -ar 48000 -c:a pcm_f32le \
            "build/cw-decoder-tests/fixtures/$number.wav"
    done
    exec build/cw-decoder-tests/CWDecoderRegressionTests build/cw-decoder-tests/fixtures
fi
exec build/cw-decoder-tests/CWDecoderRegressionTests
