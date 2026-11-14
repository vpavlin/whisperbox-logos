# ADR 0029: Respondent privacy first; creator privacy never at the cost of UX

Status: accepted, 1.1.5 (2026-11-14). Amends ADR 0027 (receipt delay) and ADR 0028 (ASK, anonymous
retries).

## Context

Audit rounds 5-9 and two privacy reviews hardened wire v2. Some of the changes in 1.1.4 cost user
experience only to hide the form's creator:
- ASK was removed, so a form missing from Store reached a respondent after up to ~75 minutes;
- receipts waited 1-5 minutes in the outbox;
- anonymous answers stopped retrying after an hour, so an answer could be lost if the creator was
  offline longer than its 6 h Store window.

Václav (2026-11-14): "we have public forms at the moment, so why do we care this much about publisher
privacy? I think responder's privacy is important, but UX should not suffer against publisher privacy."

## Decision

**The rule.** Respondent privacy is worth some UX: a respondent must not be linkable to their answers,
their device or the forms they open. Creator privacy (presence, activity timing, answer counts) is
protected only where it costs no UX, for example decoys, padding, or jitter on schedules nobody waits
for. Otherwise it is documented as accepted.

**Applied in 1.1.5:**
- **ASK is back, naming only the bucket:** `{"v": 2, "type": "ASK", "bucket": "<hex digit>"}`.
  A respondent asks for a missing form's bucket after 20 s, 10 min and 30 min, then hourly (at most
  26 times), one ASK per bucket. The creator side (creator or co-owner) answers at once by
  re-publishing its open forms in that bucket, at most once per bucket per 10 minutes.
  - A live ASK costs a frame token, and a Store copy is never acted on.
  - An older peer's `ASK{formId}` is read as its bucket.
  - A clear form id never appears (F1 stays fixed for the respondent).
  - Answering at once shows that the creator is online (F5); accepted.
- **Receipts leave within 2-10 s** of a confirmation. That is long enough to send a confirm-all, or
  a burst of automatic receipts, as one event. The outbox, per-bucket batching, decoys (at least 8
  entries) and byte-identical re-sends stay; none of them costs UX.
- **Anonymous answers keep retrying** on the normal (jittered) schedule until their receipt. Losing an
  answer is worse than the few identical copies that can be linked to each other.

**Kept, because it protects the respondent or costs nothing:**
- blinded, signed receipts (ADR 0027);
- the answers' 10-minute clock and retry jitter;
- the network-time rules;
- the creator's link for co-owner invitations (that is security, not privacy);
- the random ±25% re-publish interval.

## Consequences

- A respondent opening a link to a form missing from Store gets it within seconds again.
- An observer can again see when a creator is online (it answers ASKs and sends receipts within
  seconds). Forms are public; accepted.
- 1.1.4 creators don't answer ASKs, and 1.1.3 creators can't parse `ASK{bucket}`. Respondents fall back
  to the Store pull and the hourly re-publish until creators upgrade (test repos only).
