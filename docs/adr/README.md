# Architecture decision records

| # | decision | since |
|---|---|---|
| [0001](0001-per-form-keys.md) | Per-form sealing keys (soft-derived, Keycard-exported) | 0.3.0 |
| [0002](0002-event-log-on-one-topic.md) | Append-only event log on one shared topic | 0.1.0; RBSR catch-up 0.2.0 |
| [0003](0003-opaque-sealed-responses.md) | Answers are opaque sealed blobs, interpreted only by the creator | 0.1.0; per-form dev tag 0.3.7 |
| [0004](0004-js-reference-cpp-parity.md) | A JS reference implementation, matched by the C++ core through shared fixtures | 0.1.0; client interop 0.2.0 |
| [0005](0005-unlinkable-receipts.md) | Receipts use a random id chosen by the respondent | 0.2.0; batch receipts 0.3.2 |
| [0006](0006-creator-gated-signed-events.md) | Creator-gated events, keyed by signer, with contested-id handling | 0.2.0 |
| [0007](0007-no-public-directory.md) | No public form directory; local hide and delete | 0.3.0 |
| [0008](0008-form-lifecycle.md) | Form lifecycle: close, re-open, answer cap, close date, scheduled publishing | 0.3.2-0.3.3 |
| [0009](0009-editing-published-forms.md) | Editing published forms with form.update (latest wins) | 0.3.6 |
| [0010](0010-answer-edits.md) | Answer edits: within 15 minutes, until the receipt | 0.3.5 |
| [0011](0011-anonymous-forms.md) | Anonymous forms via a per-form derived identity | 0.3.7 desktop / 0.3.8 Android |
| [0012](0012-co-owners.md) | Co-owners receive the form key, sealed to them | 0.3.7 desktop / 0.3.8 Android |
| [0013](0013-private-replies-and-quiz.md) | Private replies and quiz scores via a per-answer reply key | 0.3.8 desktop / 0.3.9 Android |
| [0014](0014-local-state-and-data-dir.md) | Local-only state and a data folder that can't silently move | 0.3.0-0.3.4 |
| [0015](0015-shared-delivery-node.md) | Join the device's existing delivery node | 0.3.4 |
| [0016](0016-release-and-distribution.md) | Releases: binaries on an artifacts branch, signing key on one host, no CI yet | 0.3.0 |
| [0017](0017-no-google-services.md) | No Google services: local notifications, ZXing QR scanning | Android 0.3.10 |

Format: context, decision, consequences. Supersede an ADR with a new one; don't rewrite history.
