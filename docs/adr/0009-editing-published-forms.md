# ADR 0009 — Editing published forms with form.update (latest wins)

Status: accepted (0.3.6). Recorded 2026-10-03.

## Context
Users fix typos and add questions after sharing a link. Republishing under a new id breaks
the link and splits the answers.

## Decision
- `form.update` (creator-gated) carries the full new set of editable fields (title,
  description, questions, whitelist, cap, date, display options, anonymous, edit settings,
  quiz key). The latest by HLC wins. Id, creator, key, creation time, status and receipts
  never change.
- Question ids are stable: the builder keeps existing ids and mints `q<n>` above the highest
  for new questions, so existing answers still map to their questions. Answers to removed
  questions stay inside the sealed data but no longer appear in the views or the CSV.
- `version` / `updatedAt` let clients say "updated".

## Consequences
- Respondents who answered an older version keep their answers; validation applies the
  version current at submit time.
- Choice answers are stored as option indices: reordering or deleting options after answers
  came in re-labels them. Nothing prevents this today; appending options is safe.
