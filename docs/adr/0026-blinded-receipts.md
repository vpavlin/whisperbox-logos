# ADR 0026: Blinded receipts and reply addresses

Status: accepted, 1.1.3 (2026-11-14)

## Context

The privacy review of wire v2 (proteus/anoncomms, 2026-11-14, F2/F5/F8) found that receipts were the
loudest metadata left on the wire. A `response.confirm` was signed by the creator and named the form
and the answer's receipt id in clear. Anyone on the bucket learned:
- which form got receipts, how many and when, so the answer count of every form leaked;
- that the creator was online, from the signature (F5: a presence oracle);
- which receipt id a reply was for, because `response.reply.to` was the receipt id.

SPEC §14 claimed that "which form a blob answers" was never public. Receipts and replies put the form
id next to each answer's receipt id.

Václav chose blinded receipts (and Mix, which isn't deployable yet: it needs RLN memberships and a
Mix-enabled fleet; see the 1.1.3 notes).

## Decision

**A new event type `response.receipt`, unsigned, carrying tags only.**

```
tag      = hex(sha256("wb-receipt-v2|" + lc(formId) + "|" + confirmationId))
event    = { v:1, id:"rcpt:" + hex(sha256(sorted tags joined ",")), type:"response.receipt",
             hlc:{wall:now, ctr:0, dev:T}, dev:T, payload:{ tags:[1..100 tags] } }
```

- **No form id, no author and no signature.** A signature would name the sender. Admission refuses a
  receipt that has `pub` or `sig`, or any payload field other than `tags`. `T` is a fresh random
  `wb-…` tag, as on answers, never the device id. The HLC isn't the device clock's counter.
- **Who can make or recognise a tag:** the `confirmationId` is chosen at random by the respondent
  (64 bits) and is sealed inside the answer. Only the respondent and the form's owners (creator and
  co-owners) know it, so only they can make a tag or tell which answer it is for. A forged receipt
  needs that id, so a stranger can't confirm, or edit-lock, someone else's answer.
- **The fold:** `receiptTags` maps each tag to the HLC of the first receipt carrying it. It appears
  in the state only when any exist, so older golden vectors stay byte-identical.
- **Per-device resolution (`resolveReceipts`, both engines):** each device takes the
  `[formId, confirmationId]` pairs it can name: its own answers, plus the answers it opens as creator
  or co-owner. For each matching tag, the answer's id joins `form.confirmations` and its HLC joins
  `receiptHlc`. From then on every existing rule (myConfirmed, the edit lock, confirm-all, counts) works
  unchanged. `creatorView` also checks tags directly for the edit lock and its `confirmations`.
- **The keep-filter:** a receipt is kept only if one of its tags is for an answer this node can name
  (§6.2). A bystander keeps none.
- **Replies:** `response.reply.to` = `hex(sha256("wb-reply-v2|" + lc(formId) + "|" + confirmationId))`,
  not the receipt id. The reply stays signed and names its form, because its author must be checked.
  Older replies addressed by the receipt id are still read.
- **Sending:** receipts still go on their own on the form's bucket topic, 100 tags a message,
  coalesced per form, and are re-sent singly when a respondent retries (R2-7).

**Exception: forms that show respondents the answer count** (`showResponseCount`). That count is the
number of public receipts, and the creator opted in to publishing it. On those forms, receipts stay
named and signed `response.confirm` events, as before.

## Consequences

- A bystander, a Store and a relay see opaque 32-byte tags on a bucket topic. They no longer see
  which form a receipt is for, how many receipts a form got, or that its creator is online. Timing
  and the bucket (one of 16) still show.
- **Clean break for receipts:** older peers (≤ 1.1.2) refuse `response.receipt`. An old respondent
  never sees a new creator's receipt and keeps re-sending its answer on the retry schedule, each copy
  answered with the single receipt again. An old creator's `response.confirm` is still folded and
  honoured by new nodes. Upgrade creators and respondents together, as with ADR 0024.
- A creator's new device learns which answers it confirmed only after opening them (the same
  limitation as before, R3-8).
- Costs: one SHA-256 per answer a device can name, per fold, only when receipts exist; a log-wide
  scan of opened answers for the pairs (opens are cached).
