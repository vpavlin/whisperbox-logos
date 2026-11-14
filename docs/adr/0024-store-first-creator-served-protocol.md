# 0024 - Store first, creator served: WhisperBox protocol v2

Status: **accepted**, 2026-11-12. Václav's decisions are folded in below ("Decisions, 2026-11-12").

## Context

On 2026-11-12, one fresh WhisperBox node made every other node on `logos.test` send at once. Its
first catch-up round drew 236 sends from each of Václav's two Basecamps within one second, and
about 1,000 frames a minute arrived at every node. With nothing happening, each node still sends a
catch-up round every minute and answers everyone else's.

The cause is the v1 sync model, which treats WhisperBox like a shared document:
- one global topic, `/whisperbox/1/all/proto`;
- every node holds every form and every sealed answer anyone publishes;
- RBSR reconciliation every 60 s;
- every node that has an event serves it to whoever lacks it.

Traffic grows with the square of the number of nodes, and every node stores everyone's data.

WhisperBox isn't a shared document. It has two parties, and they rarely talk:
- the **creator** publishes a form and collects answers;
- a **respondent** fetches the form once, answers, and later sees a receipt.

Nobody else needs those answers. Václav, 2026-11-12: *the creator is responsible for running a
WhisperBox instance (their Basecamp or a hub) that holds their forms and accepts answers.
Respondents only publish and fetch. Use Store for publishing. With RLN enforced (a node's budget
is shared by all its apps), an idle WhisperBox must not chatter.*

### Facts this design rests on (measured or read, 2026-11-12)

- **Store retention on `logos.test` is about 48 hours.** Two fleet Store nodes (ams3,
  us-central1) return `/whisperbox/1/all/proto` messages from 0-2.0 days ago and none from 2.1
  days or older.
- **RLN on `logos.test`: 100 messages per 600 s epoch per membership,** shared by every app on the
  node. Sends over budget wait (`messageQueued`). RLN is on but not yet enforced on our nodes
  (`rln-readiness-plan`).
- **`delivery_module` v0.3.0 has the calls we need:**
  - `storeQuery(json, peerAddr, timeoutMs)`, filtering by content topic, time and message hash,
    with paging;
  - `subscribe` / `unsubscribe` per content topic;
  - `mode: "Edge"`, a light node that uses Filter and Lightpush and relays nothing;
  - Store catch-up when the node starts (`source: "history"`).
- **All topics of one app land on one relay shard.** Topics select what Filter and Store serve
  a node, not what a Core node relays (Rumor RFC-5, "Core and Edge"). Edge mode is the lever
  for CPU and bandwidth; topics are the lever for what a node has to receive and keep.
- **Rumor** (github.com/0xc1c4da/rumor, raw RFCs, rev 14, implementation 0.0.9) is a Nostr-like
  layer on Logos Delivery: signed records, 64 hashed content-topic buckets, Store catch-up per
  bucket, a publish gate on RLN state, and batching as the RLN lever. Its findings carry over.

## Decisions, 2026-11-12 (Václav)

These override the proposal below where they differ.

- **Store retention:** don't rely on 48 h. More traffic means more churn; **assume 1-2 h**.
- **Buckets:** yes.
- **Pull from Store:** yes.
- **Re-publishing:** keep doing it regularly.
  - The creator re-publishes each open form **at least once an hour**. 24 h is too long.
  - Respondents re-publish their answer **until they get a receipt**.
- **Retry backoff with no receipt:**
  - every 10 min for an hour (5 times);
  - then once an hour for a few hours;
  - then less often.
- **Edge mode:** yes. Refined 2026-11-13 (Václav): on the direct path the **studio** creates a
  **Core** node and a **respond-only** install creates **Edge**; a node already running on that
  Basecamp is adopted as it is, whatever its mode (it's shared by every app there). See section 8.
- **Clean break:** v2 doesn't talk to v1.
- **RLN for Edge (open question 1):** Lightpush does spend the service node's quota. That's a
  general Delivery-vs-RLN problem, not WhisperBox's.
- **Store peer discovery (open question 2):** check upstream; file an issue, or send a PR if we need
  one. No issue existed:
  - logos-delivery has `storeQueryToAny`, and `NodeInfoId.StoreNodes` on master, but neither is
    exposed to apps;
  - delivery_module v0.3.0 has neither;
  - an issue was filed: [logos-co/logos-delivery-module#187](https://github.com/logos-co/logos-delivery-module/issues/187).
  - Until it's fixed, use `getNodeInfo("StoreNodes")` when the node has it, else the preset
    fleet's Store nodes, trying several.
- **Creator hub (open question 3):** later, via Rumor, once it's stable.
- **Rumor:** build this design. Then do a **Rumor branch of WhisperBox** that Václav can show
  to Jarrad.

### Schedules (concrete)

| what | when |
|---|---|
| creator: re-publish an open form's `FORM` | on change, then every 60 min (jitter ±10%); a closed form 3 times over 3 h, then stop |
| creator: answer an `ASK` | re-publish `FORM`, at most once per form per 10 min |
| creator: pull its buckets from Store | on start, on reconnect, and every 15 min (queries cost no RLN) |
| respondent: `ASK` when the form isn't in Store | after 0, 10 and 30 min, then hourly while the form is open on screen |
| respondent: `ANSWER` until a receipt | at 0, then every 10 min ×5, then hourly ×4, then every 6 h, stopping after 14 days |
| respondent: pull buckets of answers still waiting for a receipt | on start, on reconnect, every 15 min |
| creator: `RECEIPTS` | when confirming (manual or automatic); a receipt that was already sent is re-sent when the same answer arrives again, at most once per answer per 10 min |
| Store query window | from the last pull (persisted per bucket), at most 6 h back |

## Proposal (as written; see the decisions above)

### 1. Form topics, no global topic

Each form lives on a bucketed topic:

```
/whisperbox/2/form-<b>/proto,   b = first hex digit of SHA-256("whisperbox.bucket.v2" || formId)
```

There are 16 buckets. A node subscribes only to the buckets of forms it created, co-owns or
opened, and keeps only what it cares about (amended 2026-11-13, see below).
- Strangers' forms and answers in its buckets DO reach it (a bucket holds ~1/16 of all forms); it
  drops them on arrival and never stores them. As first written, this line said they never reach
  it; the audit showed every node stored its whole bucket (W2-2).
- The Store peer sees which buckets a node asks about. An `ASK` still names its form in clear
  (audit W2-6, open).
- With few users a bucket is effectively one form. If one ever gets too busy, we move to
  `/whisperbox/3/` with 256 buckets.

### 2. What goes on a form topic

| frame | sent by | when |
|---|---|---|
| `FORM` - the form file of ADR 0023: signed publish + latest update + close/reopen + co-owner grants | creator (or a co-owner) | on publish or change; re-published on a schedule (4) and when asked (5) |
| `ANSWER` - the sealed `response.submit` (unchanged, opaque) | respondent | once; retried on a schedule (6) |
| `RECEIPTS` - one signed batch of receipt ids | creator / co-owner | after taking in answers; at most once per form per epoch |
| `REPLY` - a sealed reply (unchanged) | creator / co-owner | when sent |
| `ASK` - `{formId, have: version}`, unsigned, tiny | respondent | when the form isn't in Store (5) |

Gone: RBSR rounds, `SYNC_REQ`, peers serving events, and the 60 s heartbeat.

### 3. Pull from Store, then listen

- **Opening a form:** subscribe to its bucket, `storeQuery` that bucket for the last 48 h, and keep
  the newest valid `FORM`. If nothing comes back, send one `ASK` (5).
- **Creator's node, when it starts and on reconnect:** `storeQuery` its forms' buckets from the
  last time it saw them (at most 48 h back). Take in answers, then send `RECEIPTS`. Live traffic
  covers the rest.
- **Respondent, when it starts:** if any of its answers has no receipt yet, `storeQuery` those
  buckets for `RECEIPTS`.
- Bounded and pull-only: no node ever sends anything because someone else is behind.

### 4. The creator keeps its forms findable

- The creator's node re-publishes each **open** form's `FORM` frame **every 24 h**. That is half
  the retention, so a creator online once a day keeps it in Store. It is spread through the day,
  never all at once.
- A closed or expired form is re-published once (so its close is in Store), then left alone.
- Costs one message a day per open form. Václav's "every 10 minutes" would cost 144 a day per
  form; with a 48 h Store it isn't needed, but the interval is a setting.
- The creator can be their Basecamp or an always-on WhisperBox hub (`logosctl`, headless) that
  holds the form key, or a co-owner's key, so forms stay up while the laptop is shut.

### 5. Only creators answer ASKs

- When a respondent can't find a form in Store, it sends `ASK` and waits on the bucket.
- It sends at most 3 ASKs per form: after 0, 10 and 60 minutes. After that it shows
  "the creator's WhisperBox hasn't been online - try later".
- **Only nodes holding the form key** (the creator, co-owners, a creator hub) answer, by
  re-publishing `FORM`, at most once per form per 10 minutes, whoever asked. **Respondents
  never answer ASKs**: no N-copies flood.
- An ASK costs a respondent one message and the creator at most one.

### 6. Answers and receipts: send, then retry slowly

- A respondent sends `ANSWER` once and keeps it locally until it gets a receipt.
- **Retry schedule** (no receipt yet): 10 minutes, then every 24 h, for 14 days, then stop and
  show "no receipt yet". The retries cover a dropped message and a creator offline for longer
  than Store keeps things.
- The answer is byte-identical on every retry, so the creator dedups it by event id. If it was
  already confirmed, the creator re-sends that receipt at its next `RECEIPTS` batch. That is
  how a respondent who missed the receipt (offline over 48 h) still gets it.
- `RECEIPTS` and replies are sent once; the respondent fetches them from Store when it comes
  back, and the retry above covers a gap longer than 48 h.

### 7. RLN budget

- WhisperBox takes at most **10 messages per 600 s epoch by default** (10% of the node's 100).
  This is a setting; a dedicated hub may use more.
- Priority when short:
  1. `ANSWER` (first send)
  2. `RECEIPTS` and `REPLY`
  3. `FORM` (change, or answering an ASK)
  4. `ASK`
  5. scheduled `FORM` re-publish
  6. `ANSWER` retries
- Batching: one `RECEIPTS` frame per form per epoch, and one `FORM` frame carries the whole form
  state.
- Sends wait on `rlnState()` the way Rumor's do: `Initializing` defers, `Failed` holds and shows
  it, and nothing is ever dropped silently.
- Rough cost:

  | | today | v2 |
  |---|---|---|
  | idle node | ~1,440 rounds a day, plus answering everyone else's | 0 messages |
  | creator | | ~1 a day per open form, plus receipts |
  | respondent | | 1 per answer, plus at most 2-3 retries |

### 8. Lighter nodes

- `whisperbox_respond` installs (the feedback channel) run delivery in **Edge** mode: Filter on
  1-2 buckets, Lightpush to send, no relaying.
- The studio creates **Core** (decided 2026-11-13): on a desktop the node is shared by every app on
  that Basecamp, and whichever app creates it picks the mode for all of them. A creator hub runs Core.
- How the core knows: both views share one `whisperbox_core`, which looks next to its own data folder
  (`<user-dir>/module_data/whisperbox_core/<id>`) at `<user-dir>/plugins/`. `whisperbox` (the studio)
  installed → Core; only `whisperbox_respond` → Edge; not in Basecamp (logosctl) → Core. Read when the
  node is created, so installing the studio later takes effect on the next start.
  `WHISPERBOX_NODE_MODE=Core|Edge` overrides. A node that already runs is adopted unchanged.
- Loam users keep the shared node; the core asks Loam for subscriptions per bucket, never for
  `/all`.

### 9. Local engine unchanged, wire replaced

- The fold, the creator view, signatures, sealing, ADR 0022 (several answers) and ADR 0023
  (form files) stay as they are: v2 changes what goes on the wire and who sends it, not what an
  event means.
- RBSR stays only for later device sync between one person's own devices: a creator's
  Basecamp and hub, or co-owners. That runs on a private topic between them, never on a form
  topic.

### 10. Migration

- 1.0 speaks v2 only (Václav: "nobody uses this").
- The studio offers "Re-publish my forms on v2" for open forms you own; their answers so far
  stay local.
- v1 nodes keep talking to each other on `/all` until they upgrade. 1.0 neither listens there
  nor answers anything there.
- Android follows with the same JS client changes.

## Rumor: use it, or follow it?

- **Follow it now:** the same bucket scheme, Store catch-up per bucket, the RLN gate and batching.
- **Don't depend on it yet:**
  - its RFCs are `raw` and its implementation is 0.0.9;
  - `rumor_core` would add a module dependency, against ADR 0021's minimal-dependency goal for
    the respond module;
  - its own reconciliation RFC (16) is deferred.
- **Later:** forms are exactly Rumor's "public, addressable, replaceable record". Once Rumor is
  stable, publishing `FORM` as a Rumor record (and answers as private records, RFC-11) could
  replace sections 1-5. The `FORM` frame is the form file, so an adapter is small. Worth a
  conversation with its author about a WhisperBox form kind.

## Open questions

- **RLN for Edge nodes:** does Lightpush spend the service node's membership (RLNaaS), or does
  a respondent need its own? This decides whether a respond-only install can send at all once
  RLN is enforced.
- **Store peer discovery:** v0.3.0 has no "find Store peers" call. We use the preset fleet nodes,
  as for entry nodes, and should ask upstream for discovery.
- **Retention:** 48 h measured on `logos.test` today. If it shortens, the re-publish interval
  (4) and retry interval (6) follow it as settings.
- **Hub:** should we provide a "creator hub" (headless WhisperBox holding co-owner keys) as the
  recommended way to keep forms up? Václav's "or a hub".


## Amendment 2026-11-13: keep only what you care about; receipts minimal

After the independent audit of wire v2 (proteus/auditor, 2026-11-13, 13 findings). Václav:
"we should not store forms and answers we do not care about!!" and "we should keep receipts
minimal!".

**What a node keeps** (desktop core and phone client alike):
- signed events (publish, update, close/re-open, co-owner, receipt, reply) only for forms it
  created, co-owns, opened from a link (or file), answered, drafted an answer to, or hid;
- its own events, always; a co-owner grant naming it;
- answers only if they are its own (until their receipt) or a form key it holds opens them.

Everything else is dropped on arrival (`admDropUnwanted`) and pruned from the log on start,
after unlocking, and when a form is removed. A removed form's bucket stops being Store-pulled
(neither transport can unsubscribe; what still arrives live is dropped). Consequences:
- opening a link to a form not held pulls its bucket over the whole Store window (a node in the
  bucket may have heard and dropped it before);
- a node made co-owner pulls the form's bucket again over the whole window: answers sent before
  the grant were dropped because it couldn't open them then. Answers older than Store's retention
  stay unreadable to a new co-owner;
- the per-node answer cap now counts only answers the node can open or sent, so strangers can't
  fill it (they can still spam a form whose key is public; the live budgets bound that).

**Receipts:**
- a receipt goes out on its own: just the new `response.confirm` events, never the whole form
  state (that made automatic receipts O(N²) bytes, W2-5);
- receipts made while one is waiting in the send queue join it: one frame per form per send slot;
- the hourly re-publish and ASK answers carry the form definition (publish, edits, close/re-open,
  co-owners, replies), no receipts;
- a lost receipt heals through the respondent's retries: a copy of an answer the creator holds and
  has confirmed makes it send that one receipt again, at most every 10 minutes.

**The other audit findings (same day):**
- W2-1: an event is at most 80,000 bytes of JSON to be made or sent (~142 KB after both base64
  layers, under Delivery's 150 KiB); bigger forms/answers are refused with a reason. Peers still
  accept up to 256 KiB.
- W2-3: a Store reply is untrusted input: only the asked topics, at most 100 messages a page, the
  same admission and keep-filter; an ASK in it is never acted on.
- W2-4: after a reconnect (or a new transport) every bucket is joined again.
- W2-6: a live ASK costs a frame token. Form ids stay public (Václav: Rumor may improve this).
- W2-7: a held form whose creator isn't the link's doesn't stop the ASK.
- W2-8: the phone counts UTF-8 bytes like the core; `form.close.expiresAt` is 0..1e14 on both.
- W2-10: a send that fails after it left is queued again (5 tries, its budget token back).
- W2-11 (Václav: "use msg timestamp from the network rather than payload"): an answer from Store
  is judged (deadline, close) by the message's network timestamp, whatever its age (never in the
  future); a live frame's still has to be about now.
- W2-12: an empty `WHISPERBOX_STORE_PEERS` keeps the fleet list. W2-13: wire header comments.

## Amendment 2026-11-13 (2): audit round 2

The second audit round (proteus/auditor, 15 findings on the fixes above) led to:

- **Co-owner grants are invitations** (Václav). A `form.coowner` naming me is kept and shown
  (`coInvites` in the snapshot, at most 20 pending); nothing of the form is opened, kept or pulled
  until I accept it (`acceptCoOwner`): then the form and its past answers are pulled over the whole
  Store window. `leaveCoOwner` declines an invitation or stops co-owning: the form's answers go from
  this device. Forms already co-owned before this stay co-owned. (R2-1, R2-6)
- **Who may write what.** A signed event for a form I keep is kept only if its author may write it:
  close/update/re-open/co-owner by the creator; receipts and replies by the creator or a co-owner;
  `form.publish` by the creator the link names, plus at most four others in all (so a contested id
  and "this link names someone else" stay visible, and junk stays bounded). (R2-2)
- **Answers per form:** at most 20,000 kept per form, besides the node-wide 50,000, so one form's
  public key can't stop every other form taking answers. (R2-3)
- **Store pulls:** at most 100 messages a page (the rest are not even looked at) and 5,000 events a
  pull, all pages. (R2-4)
- **Network time** (Václav: relay doesn't carry old messages; ask more than one Store): every pull is
  followed by the same query to a second Store peer. A Store-delivered answer's time is the LATEST any
  Store reports, never before the window asked for; a time seen live is never changed by a Store; a
  live duplicate never moves a time earlier. A sender can still choose a time inside a pull window
  before RLN (one Store's honesty is no longer enough to backdate). (R2-5)
- **Receipts:** a retried answer that was confirmed gets ONE receipt for that answer (deterministic id,
  made once), never the batch it was in. A creator's other device that never saw the receipt shows
  the answer unconfirmed (it can confirm it again). (R2-7)
- **Own answers:** if the record of my answers is missing or behind (an old version, a damaged file, a
  crash in between), the prune keeps every answer it can't place. (R2-8)
- **Phone, a form key missing** (Keycard, after a reinstall): at most 2,000 unopenable answers are kept
  meanwhile; restoring the key prunes and pulls again. (R2-10)
- Smaller: a failed send is requeued even when the transport was replaced (C++), JS stops after 5 tries
  (R2-12); a removed bucket leaves the pull queues (R2-13); a form file with an event over the wire
  limit is refused (R2-14); a stalled loam_core forgets its joins, and the Loam path re-joins every
  10 minutes (R2-15).

Open: trial decryption still costs one ECDH per held key per answer (R2-9; bounded by the budgets
above; a per-form tag is a protocol change for later, e.g. Rumor), and the phone can't force a full
Store window yet: loam-transport's storeSync skips a topic pulled in the last minute (R2-11; ASKs and
the next pull cover it).

## Amendment 2026-11-13 (3): audit round 3

The third round (16 findings, mostly edges of round 2's own fixes) led to:

- **Invitations come from the creator only.** A `form.coowner` naming me counts only if its author is
  the form's creator (the link's pin, else the fold); with no creator known it waits as a pending
  invitation, and accepting it pins its author as the creator I trust. At most 20 pending grant events
  in all. The upgrade migration accepts only grants from the creator. Declining keeps the grant, so it
  can be accepted later; leaving a form I was never invited to is refused. (R3-1, R3-7, R3-14)
- **No creator known** (a form opened by its bare id, or before its publish): only its publishes
  (bounded) and invitations are kept, nothing else. (R3-5)
- **A co-owner's receipt** counts when the fold lists the co-owner or a creator's grant to it is held;
  in a bundle, publishes and grants are taken first. (R3-6)
- **Times:** a Store's time is never later than when we got it; the phone clamps Store times to the
  same 6 h window the desktop asks for; the FIRST live time is final (a replay never moves it).
  (R3-3, R3-4)
- **Second Store:** a failed second pass is retried (3 times) and owed passes survive a restart.
  (R3-2, R3-15)
- **Store work:** a reply over 100 full frames is refused before parsing; a pull may make us look at
  20,000 events (duplicates too) and keep 5,000 (counted after the keep-filter, so junk can't use up
  the room). (R3-10)
- **Own answers unsure:** at most 2,000 unplaceable answers kept, not the whole bucket. (R3-9)

Open, documented: one form can still be filled to its own 20,000-answer cap (R3-11); a creator's new
device can't know an answer was confirmed on another device (it confirms again; automatic receipts do it
for a hub) (R3-8); the phone's 2,000 key-missing allowance lasts until the next prune (R3-12); the phone
can't force a full Store window (R2-11/R3-13, needs loam-transport); trial decryption per key (R2-9);
with one Store peer configured there is no second opinion.

## Amendment 2026-11-13 (4): audit round 4, and where we stop

The fourth round's verdict: what remains sits at three trust seams (invitation -> creator, Store time
evidence, bounded DoS); fix R4-1, R4-3, R4-5, document the rest, and stop iterating. Done:

- **Accepting an invitation pins no one** (R4-1). The fold decides who created a form; a grant counts
  only if its author is that creator. For an accepted form without a link, the inviter's publish is
  always kept (fakes can't crowd it out). Grants from more than one author for the same form are an
  ambiguous invitation: not shown, not acceptable. C++ and JS take the same grant (the first).
- **The first evidence of an answer's time is final** (R4-3): a live copy never re-dates an answer a
  Store dated, nor an earlier live time; Stores may only raise a Store-sourced time (two Stores, the
  latest wins).
- **Own answers while their record is lost** (R4-5): the prune keeps the unplaceable answers this node
  never received from the network (every received answer has a first-seen time; one made here doesn't),
  so strangers' answers can't crowd the user's out.

Known limits, accepted for now:
- One Store peer configured (or the phone, whose host asks one Store per topic): a malicious Store can
  choose an answer's time inside the asked window (at most 6 h). Fixing it needs a second Store on the
  phone (loam-transport) or RLN-attested time.
- A Store reply may be up to ~200 MB before it is refused, and a slow Store can hold a pull for
  15 s x 20 pages; work per pull is bounded (20,000 events looked at, 5,000 kept).
- Other round-4 lows (co-owner receipt in an earlier Store page than its grant, the 20-invitation cap
  counting form ids, 4 fake publishes for a bare id, re-accepting a declined invitation in the UI,
  coowners.json from 1.1.0 not re-validated) are tracked in the round-4 report.

## Amendment 2026-11-14 (5): audit round 5 (1.1.3)

The narrow round-5 verification closed R4-5, closed R4-3 for the reported replay, and found three
adjacent cases. Fixed:

- **Invitations come from the known creator only** (R5-1, R5-2). An invitation is shown and acceptable
  only once its form's publish is held and the fold's creator (or the link's) wrote the grant. A node
  keeps the publishes of a form with a pending invitation for that. A stranger's grant is ignored, not
  treated as a "conflict" that hid the real one. A contested form (published by several keys) is shown
  as `contested` and needs the creator's link to accept. An attacker's backdated copy can't become the
  form you accept.
- **Network times must agree with the answer's HLC** (R5-3). A Store or live time more than 10 minutes
  from the answer's own `hlc.wall` is ignored. The first live time stays final; otherwise the earliest
  agreeing time wins, so an honest second Store or live copy corrects a dishonest Store, and nothing
  raises a time. Residual: a Store colluding with a late sender can backdate by up to 10 minutes; an
  honest sender whose clock is off by more than 10 minutes gets no network time (judged by first-seen).
- **Unsure answers with first-seen lost too** (R5-4): at most the newest 2,000 are kept.

Receipts became blinded in the same release (ADR 0026).

