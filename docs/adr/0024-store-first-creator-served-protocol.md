# 0024 - Store first, creator served: WhisperBox protocol v2

Status: **proposed**, 2026-11-12 (for Václav's decision; nothing built)

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

## Decision (proposed)

### 1. Form topics, no global topic

Each form lives on a bucketed topic:

```
/whisperbox/2/form-<b>/proto,   b = first hex digit of SHA-256("whisperbox.bucket.v2" || formId)
```

There are 16 buckets. A node subscribes only to the buckets of forms it created, co-owns or
opened, and filters by form id locally.
- Strangers' forms and answers never reach it or its log.
- The Store peer sees which buckets a node asks about, not which form.
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
- The studio can stay Core or go Edge; a creator hub runs Core.
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
