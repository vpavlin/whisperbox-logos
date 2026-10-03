# ADR 0002 — Append-only event log on one shared topic

Status: accepted (0.1.0; RBSR catch-up 0.2.0). Recorded 2026-10-03.

## Context
WhisperBox has no server. Forms, answers and receipts must reach every interested device,
including devices that were offline, and every device must end up with the same view.

## Decision
- All state is an append-only log of events (loam-sync shape: `{v, id, type, hlc, dev, payload}`),
  merged as a set (union by key) and ordered by HLC. Nothing is ever edited in place; edits,
  closes and receipts are new events.
- One public content topic for everything: `/whisperbox/1/all/proto`. Per-form topics would
  publish which forms are active and how busy they are, and multiply subscriptions.
- Late joiners catch up with loam-sync RBSR (fingerprints over event keys, then serve the
  difference) at 3 s / 10 s / 25 s after the node comes up. The 0.1 whole-log `SYNC_REQ`
  re-broadcast is kept only for old peers and rate-limited.
- On a key collision the copy with the earlier HLC wins, so the merged log depends only on
  the event set, never on arrival order (stricter than plain loam-sync "first seen").

## Consequences
- Convergence is testable: the engine suite folds 200 random arrival orders across 6
  replicas and requires identical state.
- The topic carries everyone's traffic; clients filter. Fine at current scale; per-form
  sharding can be added later as a second topic without changing events.
- The fleet store keeps the history (that's how late joiners catch up); sealed answers are
  useless without the form key (ADR 0003).
