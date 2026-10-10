# ADR 0018 — The protocol is a separate package (whisperbox-sdk)

Status: accepted (desktop core 0.4.2). Recorded 2026-10-10.

## Context
Frequencies (an event-organisation app on Loam) uses WhisperBox forms for booking requests,
crew sign-up, guest lists and feedback. Its phone app has to create forms and read answers
with exactly the code WhisperBox runs: the mobile fold must stay byte-identical to the
C++ fold, so a copied engine would be a fork of the data format. On the desktop nothing
needs extracting: another Basecamp module calls `whisperbox_core` (a declared dependency).

The shared code already lived apart from the app in `packages/` (contract, engine, client).
The client imported loam-sync's catch-up from outside that folder
(`third_party/loam-sync`), and the RN wiring (`mobile/src/lib/whisperbox.ts`, `store.ts`)
hard-coded the app id it registers with Loam.

## Decision
- `packages/` is its own repo, `vpavlin/whisperbox-sdk` (public, MIT OR Apache-2.0),
  split with its history and mounted back as a submodule **at the same path**, so the
  app's imports, the C++ parity/golden tests that read `packages/*/test/fixtures` and
  `scripts/test.sh` keep their paths.
- The SDK carries its own loam-sync (`packages/loam-sync-pkg`, a submodule) at the revision
  `third_party/loam-sync` pins; the app keeps `third_party/loam-sync` as the source of the
  C++ headers vendored into `whisperbox_core/src/logos_sync`. Bump both together.
- `packages/rn/` is the React Native adapter: `setAppId(id)` (default
  `xyz.vpavlin.whisperbox`, what the app has always registered), `createWhisperbox({transport,
  store?, secrets?, log?})` and `boot()` = preferServiceBackend → start. The transport is
  **injected**: the host passes its own loam-transport, so an app running several engines
  (Scala, Kith, WhisperBox) has one transport, with one receiver per engine (loam-transport
  9963f22 and later). The default stores moved there from `mobile/src/lib`.
- `packages/templates/` holds organiser form templates (booking, crew, guest list, feedback),
  plain form definitions both platforms publish unchanged.
- `formSummary(formId)` (core 0.4.2 and the JS client) gives another app's card the title,
  status and counts. Answer counts go only to the creator or a co-owner: a sealed answer
  doesn't name its form, so nobody else can count them. Receipts are public.
- Peer dependencies, not dependencies: the consuming app owns `node_modules`.

## Consequences
- An engine change is two commits, SDK first; the app's `scripts/test.sh` (which includes the
  C++ parity and interop layers) decides when it's done. Consumers bump their pointer.
- Fresh clones need `--recursive`.
