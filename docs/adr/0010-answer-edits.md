# ADR 0010 — Answer edits: within 15 minutes, until the receipt

Status: accepted (0.3.5). Recorded 2026-10-03.

## Context
Respondents make mistakes. But one answer per respondent is the rule, and a creator who
already acted on an answer (receipt sent) must not see it change.

## Decision
- Opt-in per form (`allowEdits`, `editWindowMinutes`, default 15).
- An edit is a new sealed answer from the same respondent with the same `confirmationId`.
  The creator view accepts it if stamped within the window after the first answer AND before
  the first receipt for that id; it replaces the answers in place (`edits += 1`).
- Editable forms require the inner signature, so nobody can "edit" someone else's answer by
  claiming their address.

## Consequences
- "Send receipt" doubles as "lock this answer".
- Window and receipt ordering are by HLC (same caveat as ADR 0008).
