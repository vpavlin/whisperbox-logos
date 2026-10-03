# ADR 0016 — Releases: binaries on an artifacts branch, signing key on one host, no CI yet

Status: accepted (0.3.0). Recorded 2026-10-03.

## Context
The build host's GitHub account is restricted (no releases, PRs or Actions) and the Android
signing key must never leave that host. jimmy-crib republishes builds to the mesh's
Basecamp and F-Droid repos.

## Decision
- Source on the development branch; binaries (APK + both `.lgx`) committed to the `artifacts`
  branch under `releases/0.3.x/` with `SHA256SUMS` and a README naming the source commit.
- Pushes use a per-repo deploy key.
- `scripts/release/release.sh` gates on the full test log, then commits, pushes and builds;
  `publish.sh` updates `artifacts` and verifies the uploaded hashes against the local build.
- CI stays off for now: builds need the signing key and a large nix store; revisit with a
  self-hosted runner.

## Consequences
- Releases depend on that one host. The signing key must be backed up out of band; losing
  it means the Android app can never be updated in place.
