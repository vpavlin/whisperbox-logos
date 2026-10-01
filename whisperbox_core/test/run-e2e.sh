#!/usr/bin/env bash
# Build + run the fake-SDK end-to-end test (no nix needed: system Qt6 Core,
# nlohmann-json, OpenSSL). Usage: whisperbox_core/test/run-e2e.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${WB_TEST_OUT:-${TMPDIR:-/tmp}/wb-e2e-build}"
mkdir -p "$OUT"
QTINC=$(pkg-config --cflags Qt6Core)
QTLIB=$(pkg-config --libs Qt6Core)
g++ -std=c++20 -O1 -g -fPIC -Wno-deprecated-declarations \
    -I"$HERE/fakesdk" -I"$HERE/../src" $QTINC \
    "$HERE/e2e_test.cpp" "$HERE/../src/whisperbox_core_impl.cpp" "$HERE/../src/qrcodegen.cpp" \
    $QTLIB -lcrypto -o "$OUT/e2e_test"
"$OUT/e2e_test" "$@"
