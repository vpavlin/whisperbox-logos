# 0021 - A respond module for the official catalog; Loam becomes optional

Status: proposed, 2026-11-10 (0020 is reserved for PR #3)

## Context

Basecamp needs a default feedback channel that opens one form from a link. Alisher (xAlisher/feedback-bc)
declined WhisperBox for that role for two reasons:

- it depends on our other modules (`loam_core`, and through it `ble_mesh` and `keycard`), and the official
  catalog wants a minimal dependency tree;
- it is a full form builder, where one small form opened from a link would do.

Václav: keep Loam for our own development and experiments, keep official apps' dependency trees minimal,
and do not break existing apps.

What `whisperbox_core` actually takes from `loam_core`: transport only. It makes 7 calls (start, status,
status-changed, join, sendSealed, received, senderId), with useChannels:false. Identity, crypto, sealing and
catch-up (RBSR) are compiled into the core.

## Decision

1. **Transport seam.** `whisperbox_core` talks to an internal `Transport` with two implementations:
   - `LoamTransport`: today's code, unchanged, through `loam_core`.
   - `DirectTransport`: `delivery_module` directly, through Loam's shared header
     `loam/delivery_transport.hpp` (loam-basecamp, loam_core 0.7.4). The header holds the RLN-off logos.test
     network config, the receive decoding (`{"_bytes"}`, SDS fields, SegmentMessage), the start/reconnect
     handling, and joining a node another module already started. Both sides use the same header, so the
     wire stays identical.
2. **Dependencies.** `delivery_module` is required; `loam_core` becomes optional (`optional_dependencies`).
   At start the core probes Loam with an async call: an answer means `LoamTransport`, empty or an error
   means `DirectTransport`. It never makes a sync call to `loam_core`, and never subscribes to its events
   before the probe succeeds.
3. **Two views on one core.**
   - `whisperbox` (the studio): today's view. Creating and managing forms, co-owners, responses, replies.
   - `whisperbox_respond`: a small view that provides the intent `whisperbox.respond {link}`. It opens one
     form, answers it, and shows that the answer was received. It also takes a pasted link when opened
     without an intent.
   - Both use the same core, so the protocol has one implementation.

## Not breaking existing apps

- **Wire and protocol unchanged.** Forms, answers, receipts and replies interoperate with today's Android
  app, today's desktops and the open-review bot.
- **Where Loam is installed** (every current WhisperBox desktop), the probe succeeds and the core uses
  `loam_core` exactly as today.
- **Package names stay.** `whisperbox_core` and `whisperbox` keep their names and data paths, and the core
  API only gains additions.
- **Test gates.** All 8 test layers stay green. A two-node logosctl run checks old build ↔ new build, and
  Loam ↔ direct, in both directions, before release.
- **Shared node.** One `delivery_module` node per Basecamp; the first module to create it wins. The
  header's join-the-running-node fix covers both orders. On development machines,
  `LOGOS_DELIVERY_RLN_PRESETS` makes the `logos.test` preset name itself RLN-off, so start order doesn't
  matter.

## Open

- **Finding the form when nobody holding it is online.** Options: a Store-query fallback through
  `delivery_module`, or the signed form definition carried in the link.
- **The catalog's rule:** does merely listing an optional `loam_core` count as a minimal dependency tree
  (a question for Alisher)? If not, the same source builds two flavours.
- **The cpp-sdk #134 re-subscribe workaround** stays on behind a flag until builder 0.3.3 is shown not to
  need it.
