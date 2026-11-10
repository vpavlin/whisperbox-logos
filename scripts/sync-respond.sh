#!/usr/bin/env bash
# sync-respond.sh - copy the files the studio (module/) and the respond module (module-respond/) share.
# Each Basecamp package is built from its own directory, so the respond module carries copies;
# module/ is the source. `--check` fails if a copy differs (scripts/test.sh runs it). ADR 0021.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="FormRespond.qml WbAnswers.js WbPalette.js WbButton.qml InputBox.qml SectionLabel.qml LockIcon.qml"
bad=0
for f in $FILES; do
  if [ "${1:-}" = "--check" ]; then
    cmp -s "$ROOT/module/qml/$f" "$ROOT/module-respond/qml/$f" || { echo "module-respond/qml/$f differs from module/qml/$f - run scripts/sync-respond.sh"; bad=1; }
  else
    cp "$ROOT/module/qml/$f" "$ROOT/module-respond/qml/$f"
  fi
done
[ "${1:-}" = "--check" ] && [ $bad = 0 ] && echo "respond module shares are in sync"
exit $bad
