# 0025 - WhisperBox on Rumor (branch `rumor`)

Status: **experimental**, 2026-11-12. Lives on the `rumor` branch. It has not been merged and is not
on the path to release. Václav asked for it, to show Jarrad Hope what WhisperBox looks like with
Rumor (github.com/0xc1c4da/rumor) as its transport.

## Why

ADR 0024 (wire v2) built a small version of what Rumor is for: per-form bucket topics, Store
catch-up, re-publishing, an RLN budget and a deferred send queue. Rumor does all of that as a
shared layer:
- signed, addressable, replaceable records;
- 64 hashed buckets;
- Store catch-up with persisted plans and coverage;
- publishing gated on RLN state;
- a deferred queue that survives restarts;
- batching;
- one-shot identities.

This branch replaces WhisperBox's wire with Rumor and keeps everything WhisperBox-specific:
- the event model and the fold;
- secp256k1 signatures on form events;
- answers sealed to the form key;
- receipts, replies, several answers per person, form files.

## Mapping

| WhisperBox (v2) | Rumor record | Notes |
|---|---|---|
| a form's state (`EVENTS` bundle: publish, edits, close/re-open, co-owners, receipts, replies) | class 2 **addressable**, kind `whisperbox.form`, `d` = form id, tag ref `["t", "wb:" + formId]` | A new version (`version_parents` = the current head) on every change, and hourly while open. Readers take the head. The payload is the bundle's JSON as a text ApplicationValue (`encode_text_application_value`); WhisperBox verifies every event inside, as in v2. |
| an answer (`response.submit`, sealed) | class 0 **regular**, kind `whisperbox.answer`, ref to the form's record + the same tag | Authored under a **one-shot identity** (`oneshot_open`, then `author_record{oneshot}`), so the Rumor author can't link answers to the respondent's node. Retries (ADR 0024 schedule) are new one-shot records carrying the same sealed event; the creator dedups by WhisperBox event id. |
| `ASK` | class 3 **ephemeral**, kind `whisperbox.ask`, the form's tag | Only the creator side, the subscriber for its own forms' asks, answers, by authoring a new form version. |
| bucket topics, Store pull, RLN queue | Rumor's buckets (tag facet), `subscribe(filter)` with Store catch-up, `deferred` publications, RLN gate | WhisperBox keeps only its schedule (hourly form version, answer retries until the receipt, ASK timing); Rumor sends. |

Identity: the Rumor author of a form record is the creator node's Rumor key (Ed25519). The
WhisperBox creator (secp256k1) is inside the payload and verified there, as today. A form id
squatted by another Rumor author is the existing "contested" case, decided on the WhisperBox
signatures.

## Reads

- **Respondent opening a link:** `subscribe({kinds: ["whisperbox.form"], refs: [tag "wb:<formId>"]})`.
  Rumor catches up that tag bucket from Store, then delivers live versions. The newest head
  becomes the form state, ingested through the same admission as v2 bundles. If catch-up ends
  (`catchup_attempt_end`) with no form, send an ASK.
- **Creator side:** `subscribe({kinds: ["whisperbox.answer", "whisperbox.ask"], refs: [tag "wb:<formId>"]})`
  for each form it creates or co-owns.

## What this branch shows / doesn't

It shows:
- WhisperBox's data model rides on Rumor records without changing what a form, an answer or a
  receipt means;
- ADR 0024's machinery mostly disappears into Rumor.

Open on Rumor's side (for the conversation with its author):
- **Retention.** Rumor's reconciliation (RFC-16) is deferred and Store keeps hours, so the
  creator still re-authors its form hourly. Is there a better Rumor answer (RFC-7 committed
  archives)?
- **One-shot identities for anonymous replies.** Is one handle per answer the intended use?
- **A `whisperbox` namespace in the kind registry.**

## Status of the code

See the branch's commits. The rumor_core module (0.0.9) is built from its repo, pinned. Builder
and delivery versions differ from WhisperBox's (rumor_core: builder 8f56bf8, delivery_module
v0.3.2; WhisperBox: builder 0.3.3 / 3a64943, delivery_module v0.3.0). Reconciling them is part of
the work.
