#!/usr/bin/env bash
# Every test layer that runs WITHOUT nix/Basecamp, in dependency order:
#   1. TS contract crypto        (packages/contract)
#   2. TS engine: unit + 200x6 convergence + golden vectors (packages/engine)
#   3. C++ crypto parity vs the TS golden vectors
#   4. C++ engine parity (merge/fold/creator view) vs the TS golden vectors
#   5. E2E: the REAL whisperbox_core_impl.cpp, 6 instances over a fake
#      delivery_module bus (whisperbox_core/test/fakesdk) - PLAN Phase 6 A/B/C
#   6. QML: render every fixture + interaction scenarios (view->core contract)
#   7. Interop: the JS client (Android app's protocol layer) against the REAL C++ core
# Needs: node>=20, g++ (C++20), OpenSSL + nlohmann-json + Qt6 (Core/Quick) dev
# packages, python3; layer 6 also needs a logos-design-system checkout (WB_DS,
# default: cloned to $WB_TMP).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WB_TMP="${WB_TMP:-${TMPDIR:-/tmp}/wb-test}"
mkdir -p "$WB_TMP"
step() { printf '\n== %s ==\n' "$*"; }

step "1/8 contract crypto (TS)"
( cd "$ROOT/packages/contract" && { [ -d node_modules ] || npm install --silent; } && node --test test/crypto.test.mjs test/crypto-portable.test.mjs | grep -E "^# (pass|fail)" )

step "2/8 engine (TS)"
( cd "$ROOT/packages/engine" && npm test --silent )

step "3/8 crypto parity (C++)"
g++ -std=c++17 -O1 -Wno-deprecated-declarations -I"$ROOT/whisperbox_core" -I"$ROOT/whisperbox_core/src" \
    "$ROOT/whisperbox_core/test/parity_test.cpp" -lcrypto -o "$WB_TMP/parity_test"
"$WB_TMP/parity_test" "$ROOT" | tail -1

step "4/8 engine parity (C++)"
g++ -std=c++17 -O1 -Wno-deprecated-declarations -I"$ROOT/whisperbox_core" -I"$ROOT/whisperbox_core/src" \
    "$ROOT/whisperbox_core/test/engine_golden_test.cpp" -lcrypto -o "$WB_TMP/engine_golden_test"
"$WB_TMP/engine_golden_test" "$ROOT"

step "5/8 core end-to-end (fake loam_core bus)"
WB_TEST_OUT="$WB_TMP" "$ROOT/whisperbox_core/test/run-e2e.sh" 2>"$WB_TMP/e2e.stderr" | grep -vE '^  ok' 

step "6/8 view (QML render + scenarios)"
if [ -z "${WB_DS:-}" ]; then
    [ -d "$WB_TMP/logos-design-system" ] || git clone -q --depth 1 https://github.com/logos-co/logos-design-system "$WB_TMP/logos-design-system"
    export WB_DS="$WB_TMP/logos-design-system/src/qml"
fi
export WB_OUT="$WB_TMP/render"
"$ROOT/scripts/qml-harness/render.sh" | grep -E 'PASS|FAIL|FATAL'
"$ROOT/scripts/qml-harness/scenarios.sh" | tail -1

step "7/8 interop: JS client vs C++ core"
( cd "$ROOT/third_party/loam-sync" && { [ -d node_modules ] || npm install --silent --ignore-scripts; } )
"$ROOT/whisperbox_core/test/run-bridge-build.sh" "$WB_TMP/wb-bridge" >/dev/null
( cd "$ROOT/packages/client" && { [ -d node_modules ] || npm install --silent; } && WB_BRIDGE="$WB_TMP/wb-bridge" node --test test/interop.test.mjs test/hermes-globals.test.mjs | grep -E "^(ok|not ok)|^# (pass|fail)" )

step "8/8 Keycard: real applets (3.1.2 + 4.0) in jCardSim, Hermes-like globals"
if [ -x "${JAVA_HOME:-$HOME/jdk/17}/bin/java" ] && [ -d "$ROOT/mobile/node_modules/keycard-sdk" ]; then
  [ -x "$WB_TMP/keycard-sim/sim.sh" ] || "$ROOT/scripts/keycard-sim/setup.sh" "$WB_TMP/keycard-sim" >/dev/null
  for v in 3.1 4.0; do
    ( cd "$ROOT/mobile" && KC_SIM="$WB_TMP/keycard-sim/sim.sh $v" node --import ./test/hermes-env.mjs --experimental-strip-types --no-warnings \
        --test test/keycard-sim.test.mjs | grep -E "^\s*(ok|not ok)|^# (pass|fail)" | sed "s/^/[applet $v] /" )
  done
else
  echo "SKIPPED (needs JDK 17 + mobile/node_modules)"
fi

printf '\nALL LAYERS GREEN\n'
