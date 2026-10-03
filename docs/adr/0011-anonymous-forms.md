# ADR 0011 — Anonymous forms via a per-form derived identity

Status: accepted (0.3.7 desktop / 0.3.8 Android). Recorded 2026-10-03.

## Context
Some surveys must not let the creator know who answered, yet still allow one answer per
person and receipts.

## Decision
- `anonymous: true` on the form. The respondent answers as
  `HKDF(identityPriv, "whisperbox-anon-v1", lc(formId))`: stable for that person and form
  (one answer each, edits and receipts work), unlinkable to the real address and across forms.
- Not combinable with members-only (that needs real addresses); both apps refuse it.
- Shipped together with the per-form dev tag on all answer events (ADR 0003), without which
  anonymity would leak through the device id.

## Consequences
- The creator can't tell two anonymous answers from the same person on different forms.
- Anonymity is against the creator, not against network-level observers (timing, IPs).
