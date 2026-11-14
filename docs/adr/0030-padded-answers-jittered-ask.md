# ADR 0030: Padded answers, jittered ASK

Status: accepted, 1.1.6 (2026-11-14). Follows ADR 0029 (respondent privacy first).

## Context

proteus/anoncomms re-ranked the remaining privacy work for respondents (2026-11-14):
- **Answer length (High, F2):** the sealed plaintext is JSON whose size follows the form's questions
  (form definitions are public) and ECIES keeps the length, so for choice and scale forms a blob's
  size can identify the form.
- **ASK timing (Medium):** a respondent's ASKs went out at fixed gaps (20 s, 10, 20, 60 min), so
  repeated frames from one address pinned the moment a link was opened.

## Decision

- **Answers are padded to a size class.** The sealed plaintext gets a `pad` field (a string of
  `0`s), so it is exactly 1, 4, 16 or 36 KiB: the smallest class it fits. An answer longer than
  36 KiB isn't padded (the wire cap is 80,000 bytes of event JSON, and a 36 KiB plaintext is ~74 KB
  once sealed and hex-encoded).
  - `pad` is outside the inner signature (`whisperbox-inner-v1` covers formId, respondent,
    submittedAt and answers).
  - Every creator, old or new, ignores unknown fields. No protocol change.
- **ASK gaps are jittered.** The first ASK goes 10-30 s after a link is opened; later ones after 10,
  20 and then 60 minutes, each ±30% at random.

## Consequences

- Most answers become 1 KiB of plaintext (about 2.2 KB on the wire); longer ones step up to the next
  class. That costs a little bandwidth and nothing in UX.
- Next, from the same review, needing a staged rollout:
  - every node pulls all 16 buckets and answers go to a random bucket (creators first);
  - re-sealed retries, deduplicated by (respondent, confirmationId);
  - salted whitelist commitments.
