#!/usr/bin/env bash
# build-unsigned-apk.sh - the Android release APK, UNSIGNED, for jimmy-crib/publisher to sign with the
# WhisperBox key (from 0.5.0 the publisher signs; builders never hold the key).
#
#   scripts/release/build-unsigned-apk.sh            # -> mobile/android/app/build/outputs/apk/release/app-release-unsigned.apk
#
# expo prebuild --clean regenerates android/ every time, so turning the release signing off here
# touches only generated files. Run it in the foreground or with nohup (gradle needs the memory).
# Then check the APK (package, versionCode, no Google code) and hand the publisher its URL + sha256.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
LOG="${WB_APK_LOG:-$ROOT/mobile/build-unsigned-apk.log}"
cd "$ROOT/mobile"
: > "$LOG"
npx expo prebuild --platform android --clean --no-install >> "$LOG" 2>&1
echo "sdk.dir=$ANDROID_HOME" > android/local.properties     # --clean wipes it
sed -i "s/signingConfig project.hasProperty('WB_STORE_FILE') ? signingConfigs.release : signingConfigs.debug/signingConfig null/" android/app/build.gradle
grep -q "signingConfig null" android/app/build.gradle || { echo "could not switch release signing off (build.gradle changed?)"; exit 1; }
(cd android && ./gradlew assembleRelease -PreactNativeArchitectures=arm64-v8a --no-daemon -x lintVitalRelease) >> "$LOG" 2>&1
APK=android/app/build/outputs/apk/release/app-release-unsigned.apk
AAPT2="$(ls -d "$ANDROID_HOME"/build-tools/*/aapt2 | sort -V | tail -1)"
"$AAPT2" dump badging "$APK" | grep -E "^package" | cut -c1-100
if "$AAPT2" dump badging "$APK" | grep -qE "c2dm|finsky|badge"; then echo "APK REQUESTS GOOGLE PUSH / REFERRER / BADGE PERMISSIONS"; exit 1; fi
if unzip -p "$APK" 'classes*.dex' | grep -aqE "com/google/firebase|com/google/android/gms|com/google/mlkit"; then echo "APK CONTAINS FIREBASE / PLAY SERVICES / ML KIT CODE"; exit 1; fi
echo "apk: no Firebase / Play services / ML Kit code, no push permissions"
sha256sum "$APK"
