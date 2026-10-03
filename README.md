# WhisperBox build artifacts

Binaries only - no code here. Source: branch `v0.2.0`, commit `e5047d0`.
Each release folder has `SHA256SUMS`; verify before publishing.

## releases/0.3.x

| File | What | Notes |
|---|---|---|
| `whisperbox-0.3.7.apk` | Android, `xyz.vpavlin.whisperbox`, versionName 0.3.7, versionCode 11 | arm64-v8a, minSdk 24, signed v1+v2 with the WhisperBox release key, cert SHA-256 `cab0cc05ed4d7956f259c00fe70cb774c2c3a4e69cdb64ce421bf7120d012bd4`. Updates 0.2.x/0.3.x in place. |
| `logos-whisperbox_core-module-lib-0.3.6.lgx` | Basecamp core module `whisperbox_core` 0.3.6 (linux-amd64, manifestVersion 0.3.0) | depends on `delivery_module` (0.2.3 tested) |
| `logos-whisperbox-module-0.3.6.lgx` | Basecamp view `whisperbox` 0.3.6 (ui_qml) | install together with the core (same version) |

What's new: edit published forms, answer edits (15 minutes or until the receipt), new question types, preview, templates, new-answer badges + Android notifications
- see CHANGELOG.md on `v0.2.0`.


## Publishing to the mesh repos (jimmy-crib)

```sh
git fetch origin artifacts && git worktree add /tmp/wb-artifacts origin/artifacts
cd /tmp/wb-artifacts/releases/0.3.x && sha256sum -c SHA256SUMS
```
- **F-Droid (Loam repo):** `FDROID_HOME=/home/vpavlin/fdroid-loam` + `publish.sh --apk whisperbox-0.3.7.apk --apk-package xyz.vpavlin.whisperbox`
  (first publish of this app id there: add `metadata/xyz.vpavlin.whisperbox.yml`; no CurrentVersionCode pin).
- **Basecamp LAN repo:** publish both `.lgx` (REPO_HOST=jimmy-crib.office.mesh); keep the `.lgx`
  names stable or update the index URLs; the index entries need size/sha256/rootHash from these files.
