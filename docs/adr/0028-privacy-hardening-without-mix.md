# ADR 0028: Privacy hardening without Mix

Status: in progress. F4 is done in 1.1.4; the rest are planned in the order below (2026-11-14).

## Context

The privacy review of wire v2 (proteus/anoncomms, F1-F9) and its follow-up on ADR 0026 rank what is
left once receipts are blinded (ADR 0026/0027). Mix would hide who sends what (IP, first hop). Václav
decided to wait for Mix until the fleet and RLN side are ready, so this ADR collects the changes that
help without it. Each is small and needs no protocol break unless noted.

## Decision

1. **F4, answer retries (done, 1.1.4).**
   - A retry is due at a time drawn when the answer was last sent: the base gap (10 min ×5, hourly ×4,
     then 6-hourly) × a uniform 0.7-1.3.
   - The time is stored per answer (`nextAt`), so a restart keeps it. Older entries keep the fixed
     schedule.
   - On anonymous forms an answer is retried 5 times (about an hour), then left to the Store copy
     and the creator's pull.
   - Retries stay byte-identical. Re-sealing each retry would need the engine to dedup answers by
     (formId, cid), because a several-answer form would otherwise count each one. That is a later step.
2. **F1, ASK names the form (next).** Replace `ASK{formId}` with `ASK{bucket}`. The creator answers
   by re-publishing the forms it holds in that bucket, rate-limited per bucket, and the respondent picks
   its form by id. Never send an ASK and an answer back to back.
3. **F5, presence.** Answer an ASK only at the next scheduled re-publish (a flag, not an immediate
   send), with ±25% jitter on the hourly re-publish.
4. **F6, the bucket set as a fingerprint.** Sticky random decoy buckets: 3-4 extra buckets per install,
   joined and Store-pulled with the real ones, the count a setting.
5. **F7, public metadata (optional, opt-in features).** Whitelists as commitments
   H("wb-wl"|formId|address), and co-owner events addressed by tag instead of address.
6. **F9, one master secret: no code change.** Threat model: whoever has the identity key has all of that
   install's forms and can link its answers. Mitigations are the passphrase (FR-13) and Keycard.

## Consequences

- F4: an observer can no longer match a respondent's retries to a fixed schedule, and anonymous
  answers stop being re-sent after about an hour. A creator who is offline longer finds the answer in
  the Store (6 h window), and its receipt still reaches the respondent.
- Left until Mix: IP and first-hop linkage, Store/Filter attribution, the Waku message timestamp (set
  by the sender's node; only Delivery could coarsen it), per-bucket answer counts, and the creator's
  signed events as a heartbeat.
