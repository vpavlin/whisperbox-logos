# ADR 0017 — No Google services: local notifications, ZXing QR scanning

Status: accepted (Android 0.3.10). Recorded 2026-10-03.

## Context
Android 0.3.5 added "new answers" notifications with `expo-notifications`. That library
bundles Firebase Cloud Messaging and Firebase Installations (plus their transport/encoder
libraries), the Play install referrer (via `expo-application`), and adds `c2dm.RECEIVE`,
boot/wake permissions and ~17 launcher-badge permissions, even though WhisperBox never uses
push. Without `google-services.json` Firebase was most likely never initialised, but the code
and permissions shipped. That is a poor fit for a privacy-first app and keeps it out of the
official F-Droid repository. Reported in review against 0.3.9.

Removing it was not enough: `expo-camera`'s Android barcode scanner is Google ML Kit +
`play-services-code-scanner`, which bundle Play services (`com.google.android.gms`) and
Firebase components / encoders as well.

## Decision
- WhisperBox has no push server and won't get one: notifications are posted **locally** by
  the app from its own synced state (new answers on my or co-owned forms; replies / scores
  to my answers), while the process is alive.
- `expo-notifications` is removed. A ~70-line Kotlin module (`native/localnotify`,
  installed by `plugins/withLocalNotify.js`) creates the channel and posts notifications;
  tapping one opens the form's `whisperbox://` link. Permission: `POST_NOTIFICATIONS` via
  React Native's `PermissionsAndroid`.
- `expo-camera` is removed. QR codes are read with ZXing (`zxing-android-embedded`,
  Apache-2.0, the scanner most F-Droid apps use) through a small module (`native/qrscan`,
  `plugins/withQrScan.js`) that opens ZXing's capture screen and returns the text.
- `scripts/release/release.sh` fails the release if the APK contains `com/google/firebase` or
  `com/google/android/gms` code or requests c2dm / install-referrer / badge permissions, and
  always prebuilds with `--clean` so removed plugins can't leave manifest entries behind.

## Consequences
- No notifications when the app process is dead (same as before in practice: there was no
  push sender). Background delivery depends on the Loam connection keeping the app alive.
- New dependencies must be checked for Google services before adding them (the release gate
  catches it, but late).
- ZXing's capture screen is a separate, plainer screen than the old in-app camera view.
- Scala, Qaku and the Loam app use `expo-notifications` (and the scanner apps `expo-camera`)
  too; a shared library is proposed so they get the same fix.
