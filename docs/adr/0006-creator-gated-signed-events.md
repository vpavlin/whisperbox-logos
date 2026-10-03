# ADR 0006 — Creator-gated events, keyed by signer, with contested-id handling

Status: accepted (0.2.0). Recorded 2026-10-03.

## Context
Form ids are chosen by the creator and event ids are deterministic (`close:<formId>`...),
so anyone can publish an event with the same id. Early versions let a forged copy occupy the
id and shadow the genuine event, and let a second person "publish" a form id that already
existed.

## Decision
- Every non-response event is signed (ECDSA over a canonical message binding type, HLC, dev,
  id and payload) and admission requires the signer to be `payload.author` / `creator`.
- The merge keys signed events by `id#pub`, so forgeries sit beside the real event instead
  of replacing it; the fold drops events whose author isn't the creator (co-owners: receipts
  and replies only).
- Gated events that arrive before their form are deferred and replayed after the publish.
- Two creators publishing one id: both are folded, both marked `contested`. A device shows
  its own copy, else the creator named in the share link (`&by=`), else the first. Clients
  never seal answers to a contested form unless the link pins that creator, nor when the link
  names a different creator.

## Consequences
- Share links must carry the creator (`whisperbox://form?id=..&by=0x..`).
- Id squatting is visible to users instead of silently hijacking answers.
