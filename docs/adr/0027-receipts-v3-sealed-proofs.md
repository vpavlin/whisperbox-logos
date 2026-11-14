# ADR 0027: Receipts v3, tags from a per-answer secret with sealed, signed proofs

Status: accepted, 1.1.4 (2026-11-14). Supersedes the receipt format of ADR 0026; its goals and the
showResponseCount exception stay.

## Context

proteus/anoncomms reviewed ADR 0026 as built (2026-11-14) and found three gaps.

- **A (integrity).** A v2 tag was `sha256("wb-receipt-v2|formId|cid")`, and the respondent knows
  `cid`, so it could publish a valid receipt for its own answer. The creator's and co-owners' devices
  then showed the answer as confirmed and edit-locked it. The receipt's HLC was also outside any
  signature, so anyone who saw a tag could replay it with an earlier `hlc.wall` and move the edit lock
  back. Devices could disagree on the same answer.
- **B (unlinkability).** `cid` is 64 bits and the form id is public, so 2^64 guesses per form id
  link a tag back to its form.
- **C (fingerprint).** The receipt carried the creator device's millisecond clock (`hlc.wall`). The
  same clock appears in that creator's signed events, so the receipt could be attributed to the creator.

## Decision

**A per-answer secret.**
`S = ecdhX(replyPriv, formPub) = ecdhX(formPriv, replyPub)`.
- The respondent re-derives `replyPriv` with `deriveReplyKey(identity, formId, cid)`.
- The creator and co-owners hold the form key and read `replyPub` from the opened answer.
- No one else can compute `S` (256 bits, independent of the form id).

**Receipt entries.** The payload is `{r: [{t, s}]}`:
```
t = hex(sha256("wb-receipt-v3|" || S))
s = hex(nonce12 || ChaCha20-Poly1305(K = HKDF-SHA256(S, salt "wb-receipt-v3-key"), nonce, pt, aad = t))
pt = {"at":<ms>,"pub":"<signer pub>","sig":"<r||s>"}
sig = ECDSA(sha256("wb-receipt-v3-sig|" + lc(formId) + "|" + cid + "|" + at))
```
- The signer must be the form's creator or a co-owner, so a respondent's self-signed proof is ignored.
- The edit lock is the signed `at` (the earliest valid one), never the event's HLC.
- Each device opens and verifies the proofs for the answers it can name (its own, and the ones it
  opens as an owner), then hands `[formId, cid, at]` to `resolveReceipts`. The engine stays
  crypto-free: it only keeps up to 8 entries per tag.

**The keep-filter** keeps a receipt only if one of its entries is a valid proof for an answer this
node can name. Forged, random and bystanders' receipts are never stored.

**The envelope.**
- Unsigned, no form id or author, a random `wb-…` device tag.
- HLC `{wall: floor(now / 10 min), ctr: 0}` (C).
- Real entries are padded with decoy entries of the same size (32-byte tag, 260-byte proof) to a power
  of two (at least 2, at most 64), and sorted by tag.
- At most 32 real entries per event.

**Sending.** Receipts are queued per bucket topic, not per form, so a frame doesn't show one form's
count. On a respondent's retry (R2-7) a fresh single-answer receipt is sent, at most every 10 minutes.

**Replies.** `response.reply.to = hex(sha256("wb-reply-v3|" || S))`. The reply stays signed and names
its form, which only shows the replies' count and timing per form (it rides the hourly signed state
frame, already the creator's heartbeat, F5). Older replies addressed by the receipt id are still read.

**Answers without a reply key** (before 0.3.9) can't have a secret, so they get a named, signed
receipt, as do forms with `showResponseCount` (ADR 0026).

## Consequences

- **Fixed:** the respondent can't confirm or lock its own answer, and a replay can't move the lock (A).
  Tags can't be brute-forced to link them to a form (B). The receipt carries no fine clock (C).
- **Costs:**
  - one ECDH per answer a device can name, cached in memory;
  - opening a proof (AEAD and ECDSA) only when a tag matches, also cached;
  - receipt messages grow to about 600 bytes per entry, so 64 entries come to about 40 KB.
- **Breaks 1.1.3 receipts** (test repos only): 1.1.4 drops v2 receipts as shape errors. Answers
  confirmed with them show as unconfirmed until the creator confirms again (automatic receipts do).
- **Left open:** automatic receipts and re-sends go out without a random delay, so a receipt still
  follows its answer closely in time. Planned with the F4 retry jitter. Timing, bucket and IP stay
  visible until Mix.

## Amendment 2026-11-14: audit round 6 (proteus/auditor)

Round 6 audited 1.1.3 (receipts v2). R6-4 (a backdated receipt HLC) and R6-6 (a respondent inflating
a show-count form with its own receipt) were already closed by v3: the edit lock is the signed `at`,
and a self-signed proof doesn't verify. Also done in 1.1.4:

- **R6-1, amplification:** a receipt is kept only if it brings a valid proof this node doesn't hold yet.
  Replaying a seen proof with junk entries no longer adds an event. The prune still keeps what is held.
- **R6-2, cost:** the answers this node can name (and their secrets) are cached. The cache is rebuilt
  only when an answer arrives, my answers or keys change, or forms are added; not on every log event,
  and not per receipt.
- **R6-3:** a receipt id longer than 128 characters is never used.
- **R6-6:** on a show-count form, blinded receipts are ignored; its count is named receipts only.
- **R6-7:** the phone's cache key includes accepted invitations and Keycard keys.
- **R6-9:** a node re-sends at most 30 receipts per 10 minutes in all (older respondents can't read
  new receipts and keep retrying).

## Amendment 2026-11-14 (2): audit round 7 and the privacy review of v3 (still 1.1.4)

**Audit round 7 (proteus/auditor):**
- **R7-1 (High).** A respondent could reuse one reply key for two answers, so both answers had the
  same S and the same tag, and one creator proof confirmed both. The tag is now
  `sha256("wb-receipt-v3|" || S || "|" + lc(formId) + "|" + cid)`; the reply tag likewise. The proof
  cache is keyed per answer.
- **R7-2.** The answers a node can name are kept incrementally. A new answer is opened once when it
  arrives; the full rebuild runs only when my answers, keys or forms change, or after a load or prune.
- **R7-3.** Closed by R7-1: tags are now unique per answer.
- **R7-4.** `at` must have 13 digits (sealing refuses anything else, opening rejects it), so every
  real proof is exactly as long as a decoy.
- **R7-5.** The phone checks that both keys are curve points before the ECDH.

**proteus/anoncomms on v3** ("A, B and C are closed; nothing forgeable"). The linkable leftovers are
fixed:
1. A re-send is the stored receipt event, byte-identical. A fresh one with new decoys showed which
   entry was real when two frames were compared.
2. Receipts wait in a per-bucket outbox and go out as ONE event for the bucket, so per-form groups
   aren't visible.
3. Each event is padded to at least 8 entries.
4. The outbox waits a random 1-5 min, which fits inside the respondent's first retry gap (7-13 min).
   Tests set `WHISPERBOX_RECEIPT_DELAY_MS` / `receiptDelayMs` to 0.
5. Answers' fine clocks are handled in ADR 0028 (F3).

