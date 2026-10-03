#!/usr/bin/env bash
# release.sh <commit-message-file>
#
# Gated release (docs/BUILD.md "Releasing"):
#   1. scripts/test.sh must end with "ALL LAYERS GREEN" and print no FAIL / "not ok"
#      (the log is checked, never a piped exit code)
#   2. commit everything with the given message, push the current branch
#   3. nix build the two Basecamp packages  -> $WB_OUT/relN (core), $WB_OUT/relN-1 (view)
#   4. expo prebuild + gradle assembleRelease (arm64-v8a) -> the signed APK
#   5. print what was built (APK package/version, .lgx manifest name/version)
#
# Run it in the FOREGROUND or with nohup on the 8 GB build box (gradle OOMs otherwise
# when other things run). Release signing needs WB_* in ~/.gradle/gradle.properties
# (only on the build host; without them the APK is signed with the debug key).
set -u
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 <commit-message-file>"; exit 2; }
MSG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WB_OUT="${WB_OUT:-$HOME/.cache/whisperbox-release}"
JAVA_HOME="${JAVA_HOME:-$HOME/jdk/17}"; ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export JAVA_HOME ANDROID_HOME
mkdir -p "$WB_OUT"; cd "$ROOT"

WB_TMP="${WB_TMP:-/tmp/wb-test}" bash scripts/test.sh > "$WB_OUT/test.log" 2>&1
if ! grep -q "ALL LAYERS GREEN" "$WB_OUT/test.log" || grep -qE "FAIL|not ok" "$WB_OUT/test.log"; then
  echo "TESTS RED (see $WB_OUT/test.log)"; grep -E "FAIL|not ok" "$WB_OUT/test.log" | head; exit 1
fi
grep -E "checks passed" "$WB_OUT/test.log"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A && git commit -q -F "$MSG" && git push -q origin "$BRANCH" && git log --oneline -1 || { echo "commit/push failed"; exit 1; }

[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
nix build .#whisperbox_core .#whisperbox --out-link "$WB_OUT/relN" > "$WB_OUT/nix.log" 2>&1; echo "nix $?"

cd mobile
npx expo prebuild --platform android --no-install > "$WB_OUT/prebuild.log" 2>&1
echo "sdk.dir=$ANDROID_HOME" > android/local.properties     # prebuild --clean would wipe it
(cd android && ./gradlew assembleRelease -PreactNativeArchitectures=arm64-v8a --no-daemon -x lintVitalRelease > "$WB_OUT/gradle.log" 2>&1; echo "gradle $?")
APK=android/app/build/outputs/apk/release/app-release.apk
AAPT2="$(ls -d "$ANDROID_HOME"/build-tools/*/aapt2 | sort -V | tail -1)"
"$AAPT2" dump badging "$APK" | grep -E "^package" | cut -c1-100
for f in "$WB_OUT"/relN/*.lgx "$WB_OUT"/relN-1/*.lgx; do
  tar xzf "$f" -O manifest.json | python3 -c "import json,sys;m=json.load(sys.stdin);print(m['name'],m['version'])"
done
