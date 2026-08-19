#!/usr/bin/env bash
# Render-harness runner for the whisperbox view (runs on Bosgame).
# Compiles harness.cpp against the nix-store Qt6, points QML_IMPORT_PATH at the
# design system the module flake pulls in, then renders Main.qml offscreen with
# each fixture and reports QML errors + screenshots.
#
# usage: render.sh [fixture ...]   (default: all fixtures)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDIR="$ROOT/scripts/qml-harness"
QML="$ROOT/module/Main.qml"
OUTDIR="${WB_OUT:-/tmp/wb-harness}"
mkdir -p "$OUTDIR"

# ── locate Qt6 in the nix store (prefer 6.9.x — the rev the builder closure uses) ──
pick() { for d in /nix/store/*-qt$1-6.9.*; do [ -e "$d$2" ] && { echo "$d"; return; }; done; for d in /nix/store/*-qt$1-6.*; do [ -e "$d$2" ] && { echo "$d"; return; }; done; }
QTBASE=$(pick base '/lib/libQt6Core.so')
QTDCL=$(pick declarative '/lib/libQt6Quick.so')
if [ -z "$QTBASE" ] || [ -z "$QTDCL" ]; then
    echo "FATAL: qtbase/qtdeclarative not found in /nix/store" >&2
    exit 2
fi
echo "qtbase:      $QTBASE"
echo "qtdeclarative: $QTDCL"

# Design system QML dir (transitive dep of the module flake). Prefer the BUILT
# output (has Logos/Theme/qmldir), not a -src checkout.
DS=""
for d in /nix/store/*-logos-design-system-*/lib; do
    if [ -f "$d/Logos/Theme/qmldir" ]; then DS="$d"; break; fi
done
[ -z "$DS" ] && DS=$(find /nix/store -maxdepth 4 -path "*logos-design-system*" -name qmldir 2>/dev/null | grep "Logos/Theme/qmldir" | head -1 | xargs -r dirname | xargs -r dirname)
echo "design sys:  ${DS:-NOT FOUND}"

# ── compile the harness (moc first) ──
MOC=$(for d in /nix/store/*-qtbase-6.*; do [ -x "$d/bin/moc" ] && { echo "$d/bin/moc"; break; }; done)
[ -z "$MOC" ] && MOC=$(find /nix/store -maxdepth 3 -name moc -type f 2>/dev/null | head -1)
CXXFLAGS="-std=c++17 -fPIC -O1"
INCS="-I$QTBASE/include -I$QTBASE/include/QtCore -I$QTBASE/include/QtGui -I$QTDCL/include -I$QTDCL/include/QtQml -I$QTDCL/include/QtQuick"
LIBS="-L$QTBASE/lib -L$QTDCL/lib -lQt6Quick -lQt6Qml -lQt6Gui -lQt6Core"

cd "$HDIR"
"$MOC" harness.cpp -o harness.moc || { echo "FATAL: moc failed" >&2; exit 2; }
g++ $CXXFLAGS $INCS harness.cpp -o harness $LIBS || { echo "FATAL: g++ failed" >&2; exit 2; }
echo "harness built: $HDIR/harness"

# ── run against fixtures ──
FIXTURES=("$@")
[ ${#FIXTURES[@]} -eq 0 ] && FIXTURES=("$HDIR"/fixtures/*.json)

export LD_LIBRARY_PATH="$QTBASE/lib:$QTDCL/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# QML plugin roots: QtQuick.{Controls,Layouts,...} live under lib/qt-6/qml in this
# store layout; the design system is a pure-QML module under its lib/ dir.
QMLPATH="$QTDCL/lib/qt-6/qml"
[ -n "$DS" ] && QMLPATH="$DS:$QMLPATH"
export QML_IMPORT_PATH="${QML_IMPORT_PATH:+$QML_IMPORT_PATH:}$QMLPATH"

FAIL=0
for F in "${FIXTURES[@]}"; do
    NAME=$(basename "$F" .json)
    echo "── rendering fixture: $NAME ──"
    if ./harness "$QML" "$F" "$OUTDIR/$NAME.png" 2> "$OUTDIR/$NAME.log"; then
        echo "PASS: $NAME (screenshot $OUTDIR/$NAME.png)"
    else
        RC=$?
        echo "FAIL($RC): $NAME — see $OUTDIR/$NAME.log"
        grep -E "\[W\]|\[E\]" "$OUTDIR/$NAME.log" | head -15
        FAIL=1
    fi
done
exit $FAIL
