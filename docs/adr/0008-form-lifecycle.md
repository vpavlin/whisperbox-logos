# ADR 0008 — Form lifecycle: close, re-open, answer cap, close date, scheduled publishing

Status: accepted (0.3.2-0.3.3). Recorded 2026-10-03.

## Decision
- `form.close` / `form.reopen` are creator-gated with nonce ids (they can repeat). The fold
  keeps every closed period; answers stamped inside any closed period stay dropped after a
  re-open (re-opening doesn't revive them).
- `maxResponses`: the first N answers by HLC count, so every replica accepts the same N.
  `expiresAt`: answers stamped after it don't count.
- The creator's device closes a form automatically when it fills up or passes its date
  (housekeeping every 5 s). Re-open is refused at the cap or after the date (it would close
  again immediately).
- Drafts can carry `publishAt`; housekeeping publishes them when due (local only, so the
  creator's device must be running).

## Consequences
- All of this is judged by HLC, i.e. by the sender's clock. A respondent with a wrong clock
  can land just inside or outside a window. Accepted: the alternative needs a trusted clock
  we don't have.
- Auto-close needs the creator's device (or a hub holding the identity) to be online; the
  cap and date are enforced by every reader regardless.
