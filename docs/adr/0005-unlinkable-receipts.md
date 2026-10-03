# ADR 0005 — Receipts use a random id chosen by the respondent

Status: accepted (0.2.0; batch receipts 0.3.2). Recorded 2026-10-03.

## Context
A respondent wants to know the creator received the answer. A public receipt keyed by
(form, respondent) would publish who answered.

## Decision
- The respondent puts a random `confirmationId` (8 bytes) inside the sealed answer and keeps
  it. The creator's `response.confirm` echoes only `{formId, confirmationId}`; only the
  respondent recognises it.
- "Confirm all" sends one event with `confirmationIds[]`. Automatic receipts (opt-in per
  form) send batches from housekeeping.
- Edits reuse the original id, so a receipt means "this person's answer", and it also locks
  edits (ADR 0010).
- Pre-0.2 answers fall back to a legacy hash id.

## Consequences
- Everyone sees how many receipts a form got (optionally shown as a response count), not by
  whom.
- Private replies are addressed by the same id (ADR 0013).
