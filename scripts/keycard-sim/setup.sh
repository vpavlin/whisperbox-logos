#!/usr/bin/env bash
# Builds the REAL Keycard applet (status-keycard, from source) for jCardSim, so the phone's
# Keycard code (mobile/src/lib/keycard/card.ts + keycard-sdk) is tested against what a card
# runs. Two applet generations: 3.1.2 (cards in the field, e.g. appVersion 0x0301) and 4.0.
# Usage: setup.sh <outdir>   -> <outdir>/sim.sh 3.1|4.0  (APDU hex lines on stdin/stdout)
# Needs: git, a JDK 17 (JAVA_HOME or ~/jdk/17).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?outdir}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); cd "$OUT"
JAVA_HOME=${JAVA_HOME:-$HOME/jdk/17}; J=$JAVA_HOME/bin
fetch() { # repo dir ref
  [ -d "$2/.git" ] || git clone -q https://github.com/$1.git "$2"
  git -C "$2" fetch -q --depth 1 origin "$3" 2>/dev/null || git -C "$2" fetch -q origin
  git -C "$2" checkout -q "$3"
}
fetch keycard-tech/status-keycard applet-3.1 3.1.2
fetch keycard-tech/status-keycard applet-4.0 6f8544a          # master, 2026-10 (4.0)
fetch status-im/jcardsim jcardsim e1e351a5adebf203e36eec57d608ebaa6a9c55fb
SJ=$OUT/jcardsim/jcardsim-3.0.5-SNAPSHOT.jar; KM=$OUT/applet-4.0/keycard-math/keycard-math.jar
# 4.0 asks for TRANSIENT_DESELECT key objects, which this jCardSim lacks; on a card that only
# chooses RAM vs EEPROM for scratch keys - no logic change. Simulator copy only.
rm -rf src40 && cp -r applet-4.0/src/main/java src40
grep -rl "TRANSIENT_DESELECT\|TRANSIENT_RESET" src40 | xargs sed -i -E 's/(TYPE_[A-Z_]+)_TRANSIENT_(DESELECT|RESET)/\1/g'
rm -rf cls31 cls40 && mkdir cls31 cls40
$J/javac -nowarn -source 8 -target 8 -cp "$SJ" -d cls31 applet-3.1/src/main/java/im/status/keycard/*.java "$HERE/CardServer.java" 2>&1 | grep -E "error" && exit 1 || true
$J/javac -nowarn -source 8 -target 8 -cp "$SJ:$KM" -d cls40 src40/im/status/keycard/*.java "$HERE/CardServer.java" 2>&1 | grep -E "error" && exit 1 || true
cat > sim.sh <<SIM
#!/bin/sh
C=$OUT/cls31; [ "\$1" = "4.0" ] && C=$OUT/cls40
exec $J/java -XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote -XX:-BytecodeVerificationLocal -cp \$C:$SJ:$KM CardServer
SIM
chmod +x sim.sh
echo "keycard sim ready: $OUT/sim.sh 3.1|4.0"
