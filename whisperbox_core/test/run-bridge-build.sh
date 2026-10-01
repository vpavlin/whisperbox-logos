#!/usr/bin/env bash
# Build the C++ core <-> stdin/stdout bridge used by packages/client/test/interop.test.mjs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/wb-bridge}"
g++ -std=c++20 -O1 -g -fPIC -Wno-deprecated-declarations -I"$HERE/fakesdk" -I"$HERE/../src" $(pkg-config --cflags Qt6Core) \
    "$HERE/bridge.cpp" "$HERE/../src/whisperbox_core_impl.cpp" "$HERE/../src/qrcodegen.cpp" $(pkg-config --libs Qt6Core) -lcrypto -o "$OUT"
echo "$OUT"
