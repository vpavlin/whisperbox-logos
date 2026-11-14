# ADR 0028: Privacy hardening without Mix

Status: in progress. F1, F3 (answers), F4 and F5 are done in 1.1.4; F6 and F7 are planned (2026-11-14).

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
2. **F1 + F5, ASK (done, 1.1.4): ASK is removed.** anoncomms pointed out that a creator answering
   ASKs only at its next scheduled re-publish (the F5 fix) makes ASK a no-op. The re-publish happens
   anyway, and Store holds the copies. So respondents no longer send ASK (it named the form in clear,
   F1), and creators ignore older peers' ASKs (no presence oracle, F5). A missing form arrives with
   the next Store pull or the creator's hourly re-publish. The re-publish interval is drawn at random
   per send (±25%), where it was a fixed per-form offset predictable from the public form id. A clean
   break on the test repos.
3. **F3, the sender's clock (done for answers, 1.1.4).** An answer's HLC is the 10-minute mark it was
   sent in, plus a counter that keeps one window's answers (edits) in order. Its network time must
   be within [−10, +20] min of it. Without a network time (BLE), close and expiry checks judge the
   answer by that mark, so it can count up to 10 min late. Signed events keep their HLC: anoncomms
   advised against flooring them, since closes compare against them and two of a creator's devices
   would race.
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
