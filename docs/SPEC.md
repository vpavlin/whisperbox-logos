# WhisperBox protocol and application specification

Version: protocol v1, as implemented by desktop 0.3.8 / Android 0.3.9 (2026-10-03).

WhisperBox is a forms app with no server. A creator publishes a form on a shared,
public topic; respondents seal their whole answer to that form's key; everyone syncs an
append-only event log peer to peer. Only the creator (and co-owners the creator chooses) can
read answers.

Normative sources, in order: the JS reference (`packages/contract`, `packages/engine`),
pinned by the shared fixtures (section 14), then this document. The C++ core
(`whisperbox_core`) and the JS client (`packages/client`, the phone) must match the
reference byte for byte where fixtures exist. If this text and the reference disagree, the
reference wins and this text is a bug.

Terms: MUST / MUST NOT / SHOULD as in RFC 2119. `lc(x)` = ASCII lower-case. Hex is
lower-case, no `0x` unless stated. JSON numbers are IEEE doubles; ids and keys are strings.

---

## 1. Roles

| role | can |
|---|---|
| **creator** | publish, edit, close, re-open a form; read its answers; send receipts, replies, scores; add co-owners |
| **co-owner** | read a form's answers; send receipts, replies, scores; export CSV. Not: edit, close, re-open, add co-owners |
| **respondent** | answer a form once (edit within the window if the form allows); read receipts, replies, scores addressed to its own answer |
| **relay / hub** | store and re-serve every event; reads nothing sealed |

## 2. Keys and identities

All keys are secp256k1. Public keys are 33-byte compressed (`pub33`), written as 66 hex.

| name | definition |
|---|---|
| identity | random 32-byte private key per install (or imported) |
| address | `"0x" + hex(sha256(pub33))[24..64]` (last 20 bytes of sha256 of the compressed key) |
| form key (soft) | first valid scalar of `HKDF-SHA256(ikm=identityPriv, salt="whisperbox-formkey-v1", info=utf8(lc(formId)) [+ "#" + i for retry i >= 1], L=32)` |
| form key (Keycard) | exported from `m/43'/60'/1581'/i0'/i1'/i2'/i3'`, where `i0..i3` = `sha256("logos-whisperbox-form:" + lc(formId))[0..16]` read as four u32 big-endian, each `& 0x7fffffff` |
| anonymous identity | first valid scalar of `HKDF-SHA256(identityPriv, salt="whisperbox-anon-v1", info=utf8(lc(formId)) [+ "#" + i])` |
| reply key | first valid scalar of `HKDF-SHA256(identityPriv, salt="whisperbox-reply-v1", info=utf8(lc(formId) + "\|" + confirmationId) [+ "#" + i])` |
| device id | random per install; stamps HLCs and (non-response) events |
| response dev tag | `"wb-" + hex(6 random bytes)`, fresh for every answer (0.4.3). Before: `"wb-" + hex(sha256(utf8(deviceId + "\|" + lc(formId))))[0..12]` - linkable, since every signed event carries the device id in clear (review 2026-10-22, WB-5) |

"First valid scalar": retry with `i = 1..7` while the HKDF output is 0 or >= n. Legacy forms
(before 0.3) used the identity key itself as the form key (`form.publicKey == identity pub`);
those still open with the identity key.

## 3. Cryptographic primitives

### 3.1 Canonical JSON (`cjson`)
Keys sorted by code unit, no whitespace, `null` for null/undefined, strings and numbers as
`JSON.stringify`. Used only inside signatures.

### 3.2 Event signature
```
msg    = "whisperbox-sig-v1|" + type + "|" + hlc.wall + "|" + hlc.ctr + "|" + (hlc.dev || dev) + "|" + id + "|" + cjson(payload)
digest = sha256(utf8(msg))
sig    = ECDSA(identityPriv, digest), low-S, compact r||s (64 bytes hex); pub = identity pub33 hex
```
Verification: the signature verifies over the digest AND `address(pub) == lc(payload.author)`
(`payload.creator` for `form.publish`).

### 3.3 Inner response signature
Signed inside the sealed answer (never visible on the wire):
```
msg = "whisperbox-inner-v1|" + JSON({"formId","respondent","submittedAt","answers"})   // this key order, compact
```
`formId`/`respondent` lower-cased; `answers` keep their own key order (`{questionId, value}`).
Valid iff the ECDSA signature verifies with the sealed `pub` and `address(pub) == respondent`.

### 3.4 ECIES seal
```
eph        = random key; ephPub = pub33(eph)
K          = HKDF-SHA256(ikm = x-coordinate of ECDH(eph, recipientPub), salt = "whisperbox-ecies-v1", info = "", L = 32)
nonce      = 12 random bytes
ct||tag    = ChaCha20-Poly1305(K, nonce, plaintext, aad = recipientPub33 || ephPub33)
sealed     = 0x01 || ephPub(33) || nonce(12) || ct || tag(16)          -> hex on the wire
```
Opening checks version `0x01`, length >= 62 and the AEAD tag. Golden vectors use a
deterministic nonce (`sha256("whisperbox-nonce-v1|" || eph || recipientPub)[0..12]`); real
seals MUST use random nonces.

## 4. Events

### 4.1 Envelope
```json
{ "v": 1, "id": "...", "type": "...", "hlc": {"wall": ms, "ctr": n, "dev": "..."}, "dev": "...",
  "payload": { ... }, "pub": "<pub33 hex>", "sig": "<64-byte hex>" }
```
`pub`/`sig` are present on signed (creator-gated) events and MUST be absent on
`response.submit`.

HLC (loam-sync): `send(now)`: if `now > wall` then `wall = now, ctr = 0` else `ctr += 1`.
`receive(h)`: advance `wall`/`ctr` past `h`. Total order: `wall`, then `ctr`, then `dev`
(string compare), then event `id`.

### 4.2 Types

| type | id | signed | payload |
|---|---|---|---|
| `form.publish` | `form:<formId>` | yes (creator) | form definition, section 4.3 |
| `response.submit` | `resp:<hex(sha256(utf8(encryptedPayload)))>` | **no** | `{encryptedPayload}` |
| `response.confirm` | `confirm:<formId>:<cid>`; batch `confirm:<formId>:b:<hex(sha256(sorted cids joined ","))[0..16]>` | yes | `{formId, author, confirmationId}` or `{formId, author, confirmationIds:[..]}` |
| `form.close` | `close:<formId>:<nonce>` (legacy `close:<formId>`) | yes | `{formId, author, expiresAt: null}` |
| `form.reopen` | `reopen:<formId>:<nonce>` | yes | `{formId, author}` |
| `form.update` | `update:<formId>:<nonce>` | yes | `{formId, author, form: <editable fields>}` |
| `form.coowner` | `coowner:<formId>:<owner address>` | yes | `{formId, author, owner, sealedKey}` |
| `response.reply` | `reply:<formId>:<to>:<nonce>` | yes | `{formId, author, to: <receipt id>, sealed}` |

`formId` in payloads and ids is lower-case. Nonces are 6 random bytes hex.
`response.submit` events carry the random answer tag (section 2) in both `dev` and `hlc.dev`,
never the real device id.

### 4.3 Form definition (`form.publish` payload)
```
id, creator (address), publicKey (form key pub33 hex), createdAt (ms),
+ editable fields:
  title: string                 description: string
  questions: [Question]         whitelist: {type: "none"|"addresses", value: "0xa,0xb"}
  expiresAt: ms | null          maxResponses: positive integer | null
  showResponseCount: bool       thankYou: string        shuffleQuestions: bool
  anonymous: bool               quizKey: hex | null
  allowEdits: bool              editWindowMinutes: positive integer (15 when allowEdits) | null
```
Writers SHOULD omit fields at their default. Readers normalise with `editableFields(p)`:
wrong-typed or missing values become the defaults shown above. `form.update.form` carries
the same editable fields (the full new set, not a patch).

Constraints enforced by writers (core and client refuse to publish):
`anonymous` and `whitelist.type = "addresses"` are mutually exclusive.

### 4.4 Questions
```
{ id, type, text, required: bool, help?: string,
  options?: [string], allowOther?: bool, shuffleOptions?: bool,          // choice types
  min?, max?, minLabel?, maxLabel?, style?: "numbers"|"stars" }          // scale / number
```
Question ids are stable: an edit MUST keep the ids of existing questions (answers are keyed
by id). New ids are `q<n>` above the highest existing `q<n>`.

| type | answer value | valid when |
|---|---|---|
| `text`, `textarea` | string | string |
| `email` | string | matches `^[^\s@]+@[^\s@]+\.[^\s@]+$` after trim |
| `url` | string | matches `^https?://\S+\.\S+$` (case-insensitive) after trim |
| `radioButtons`, `dropdown` | option index, or `{other: string}` if `allowOther` | integer in `[0, options.length)`, or non-blank other |
| `checkbox` | `[index...]` (+ at most one `{other}`) | distinct valid indices, at most one non-blank other |
| `boolean` | `true` / `false` | boolean |
| `scale` | integer | in `[min ?? 1, max ?? 5]` |
| `number` | finite number | within `min` / `max` when set |
| `date` | `"YYYY-MM-DD"` | a real calendar date |
| `time` | `"HH:MM"` | 24-hour |
| `section` | none | always (a page break / heading) |
| unknown | string | string (forward compatibility) |

Empty (null, blank string, empty list, blank other) is valid unless `required`. Respondent
clients MUST validate before sealing (`validateAnswers`); the creator can't ask again.

## 5. Sealed payloads

| what | sealed to | plaintext (JSON) |
|---|---|---|
| answer (`response.submit`) | `form.publicKey` | `{formId, respondent, submittedAt, answers:[{questionId, value}], signature, pub, confirmationId, replyPub}` |
| co-owner key (`form.coowner.sealedKey`) | co-owner's identity pub | utf8 of the form private key in hex (64 chars) |
| quiz answer key (`quizKey`) | `form.publicKey` | `{questionId: {answer, points?}}` (section 9) |
| reply (`response.reply.sealed`) | the answer's `replyPub` | `{message, from, at}` or `{kind: "score", score, outOf, correct: {qid: bool}, from, at}` |

Answer fields: `respondent` = the address answering (the anonymous identity on anonymous
forms); `confirmationId` = 8 random bytes hex chosen by the respondent, reused on edits;
`replyPub` = the reply key's pub33; `signature`/`pub` = inner signature (section 3.3), present
when the form has a whitelist or allows edits, else `null`.

## 6. Transport and sync

- One content topic for everything: **`/whisperbox/1/all/proto`**.
- Wire message: base64 of the UTF-8 JSON control envelope. Receivers MUST accept single and
  double base64.
  - `{"type": "EVENT", "event": <event>}`
  - `{"type": "RBSR", ...}`: loam-sync range-based set reconciliation over event **keys**
    (section 7). A node runs a round 3 s, 10 s and 25 s after its node comes up and after
    joining a form, answering peers' rounds by serving the missing events.
  - `{"type": "SYNC_REQ", "from": deviceId, "rbsr": true?}`: legacy 0.1.x catch-up. Flagged
    requests are ignored; unflagged ones trigger at most one full re-broadcast per 3 s.
- Desktop (0.4.x): through `loam_core`, the shared transport module, started with
  `{mode: "Core", preset: "logos.test", useChannels: false}`: a plain relay publish on the topic.
  Delivery 0.3's reliable channels are off on purpose: they held back every message whose causal
  history the node hadn't seen, so a desktop received nothing from a phone with history. The
  RBSR catch-up above provides the reliability. `$WHISPERBOX_DELIVERY_CFG` (JSON) replaces the
  config. If another app already started the shared node, joining it is enough.
- Phone: via loam-transport (the Loam shared node or its own node). loam_core unwraps the
  phones' channel frames on the relay path, and phones accept plain relay frames.
- Transport status: the view shows loam_core's status as it changes, including after the first
  connect (e.g. "Transport stalled: ..."); a return to "Connected" runs a catch-up round.
- Events are broadcast only while the node is up; local events wait in the log and go out
  through catch-up.

### 6.1 Admission (receive)
Before merging a received event:
- `form.publish`: MUST verify (section 3.2, signer == `payload.creator`).
- creator-gated types: MUST verify (signer == `payload.author`). Whether the author may do
  it is decided later, in the fold.
- `response.submit`: MUST NOT carry `pub`; MUST have `payload.encryptedPayload`; its `id` MUST be
  `resp:` + the hash of that payload (section 4.2), else a copy could shadow a real answer.
- anything else: dropped.

From 0.4.3 (review 2026-10-22), before any of the above, every event MUST be well formed or it is
dropped (`wellFormedEvent`, the same rules in `whisperbox_core` and `packages/client`): string
`id`/`type`, `hlc` with non-negative integer `wall`/`ctr`, an object `payload`, and each type's
payload fields with their JSON types (form definitions: an array of question objects with string
`id`/`type`, typed options and flags). An event whose `hlc.wall` is more than 5 minutes ahead of
the receiver's clock is dropped, and a clock is never moved forward by such an event. Catch-up
messages are checked the same way before they are answered. Loading a log applies the same rules:
an event that fails is skipped and kept in `events.bad.json`. Nothing a peer sends may stop the
node: a frame that fails to process is counted (`rxBad`) and dropped.

From 0.5.1 (open-review 2026-10-29):
- **Frames:** a decoded frame over 1 MiB, or JSON nested more than 32 deep, is refused before it
  is parsed (`rxBad`). One 100 KB frame nested 50,000 arrays deep used to overflow the stack in
  the canonical-JSON signer, before any signature was checked (FR-1).
- **Events:** a whole serialized event is at most 256 KiB (FR-6), and `hlc.ctr` is at most 2^30. A
  peer's `LLONG_MAX` counter used to make the next local stamp overflow (FR-2); a local counter
  at the bound carries into the next millisecond.
- **Form keys:** a `form.publish` `publicKey` must be a point on secp256k1, and ECDH refuses an
  invalid point. An invalid key gave an all-zero shared secret, so anyone could open the answers
  (FR-4). The same check applies to co-owner codes.
- **Loading:** signed event types are verified again when a log is loaded; the fold trusts the
  log (FR-7).
- **Serving for others** (RBSR `ids`/`need`, a legacy `SYNC_REQ`) is bounded:
  - at most 100 events for one incoming frame;
  - an event served in the last 2 s isn't served again;
  - at most 300 a minute (`serveSkipped`).
  A 40-byte `ids` frame used to make the node re-broadcast its whole log, every time (FR-3).
- **Unverified answers** don't get automatic receipts and don't count towards the auto-close at
  the cap. The CSV export has `verified` and `timeVerified` columns (FR-5).

## 7. Merge

The log is a set of events kept in total HLC order.
- Dedup key: `id + "#" + pub` for signed events, `id` for unsigned ones (ids are not bound to
  the author, so a forged copy must not shadow the real one).
- On a key collision the copy with the **earlier HLC** wins. The merged log is therefore a
  function of the event set alone, independent of arrival order.

## 8. Fold (`computeState`)

Replay the merged log in order. State: `forms`, `feed` (open forms by publish order),
`responses` (opaque pool `{id, hlc, encryptedPayload}` in HLC order), `closeHlc`,
`closedSpans`, `receiptHlc`, `pending` (deferred events), `dropped` (count + reasons).

Form view = definition fields + `status` ("open"/"closed"), `confirmations` (receipt ids),
`coOwners` (`[{address, sealedKey}]`), `replies` (`[{to, sealed, hlc}]`), `version` (1 + number
of updates), `updatedAt` (wall of the latest update), `contested`.

Rules, per event:
- `form.publish`: first publish of an id creates the form. A publish of the same id by a
  **different** creator is id squatting: every contender is folded separately and all of
  them are marked `contested`. The device shows its own copy, else the creator pinned by
  the share link it opened, else the first.
- `response.submit`: appended to the pool. Never inspected or dropped here.
- creator-gated events whose form isn't folded yet are **deferred** and replayed right after
  that form's publish (lenient ordering).
- Author check: `payload.author` must be the form's creator. Exceptions: co-owners may author
  `response.confirm` and `response.reply`. An author who is a contender for a contested id
  applies to its own copy. Otherwise dropped (`not-creator`).
- `form.update`: replace all editable fields; `version += 1`; `updatedAt = hlc.wall`. Status,
  receipts, closes, co-owners and replies are untouched. Latest (by HLC) wins.
- `response.confirm`: add each new receipt id to `confirmations`; remember the HLC of each
  id's first receipt in `receiptHlc[formId][cid]`.
- `form.close`: `status = closed`; open a closed span `{from: hlc, to: null}` unless one is
  open. `form.reopen`: `status = open`; close the open span (`to = hlc`). Last one wins.
- `form.coowner`: owner must be a `0x` + 40-hex address and `sealedKey` non-empty
  (`bad-coowner`); replaces any previous entry for that owner.
- `response.reply`: `to` and `sealed` non-empty (`bad-reply`); identical `sealed` deduped.

## 9. Creator view (`creatorView`)

Run by a creator or co-owner over the pool, in HLC order, with the keys it holds (its own
forms' keys plus co-owned form keys opened from `form.coowner`).

**Answer time (ADR 0019).** A client passes `netTime(eventId)`: the earliest Logos Delivery
timestamp (ms) it has seen for that `response.submit` (live, from the store, or a re-served copy;
kept locally, `wb-nettime` / `nettime.json`, never synced). With it, an answer's time `t` is that
network time, the pool is processed in `t` order (HLC breaks ties), and every rule below that
says "stamped" compares `t` (against a creator-signed HLC by wall clock). An answer with no
network time (BLE, an older transport) uses its own `hlc.wall` as before. Without `netTime` the
view is the HLC-only fold (identical on every replica; the golden vectors). For each blob:

1. Trial-open with every held form key (cached per blob; retried only when the key set
   grows). Not openable means `undecrypted`. The opening key MUST be the `publicKey` of the
   form named in the plaintext, otherwise the blob is ignored. Blobs don't name their form on
   purpose: that would publish per-form answer counts.
2. Drop if stamped inside any closed span (`from <= t < to`) (`form-closed`), or if
   `t > expiresAt` (`expired`).
3. Inner signature: a signed answer must verify and be signed by the `respondent` it names
   (`sig-invalid`). Unsigned: dropped on forms with a whitelist or `allowEdits` (`sig-invalid`);
   on an open form kept as `verified: false`, outside steps 4-6 (no respondent slot, no cap, no
   edits). Every 0.5.0 client signs; unsigned answers come from older clients or forgers.
4. `respondent` required (`no-respondent`); whitelisted forms: respondent must be listed
   (`not-whitelisted`).
5. Same respondent seen before for this form:
   - not `allowEdits` -> `duplicate-respondent`;
   - stamped more than `editWindowMinutes` after the first answer -> `edit-too-late`;
   - at or after the first receipt for that answer's `confirmationId` -> `edit-after-receipt`;
   - else it is an **edit**: replace `answers`, `submittedAt`, `signature`, `replyPub` of the
     existing entry and `edits += 1`. Position and `confirmationId` stay.
6. Answer cap: once `maxResponses` answers are accepted, later first answers are dropped
   (`over-limit`). "First N" is by HLC, so identical on every replica.
7. Accept: `{respondent, submittedAt, answers, signature, confirmationId, hlc, replyPub?, edits?}`
   (`edits` only on forms that allow edits), plus `verified: true` with a verifier, and with
   `netTime`: `timeVerified` (a network time was seen), `receivedAt` (it, or null) and
   `timeSkew: true` when the signed `submittedAt` is more than 5 minutes from it.

The network time is a time the network vouches the answer existed by: with RLN on, relays refuse
a message stamped more than ~20 s from their clock and the timestamp is bound into the proof.
Without RLN (our nodes today) it is only as honest as the sender's node. Answers without one are
judged by their own HLC and shown as "time not verified" (ADR 0008, ADR 0019).

## 10. Module layer (core and client, not the engine)

Per accepted answer the creator/co-owner additionally gets `confirmed` (its receipt id is in
`confirmations`), `replies` (count of `response.reply` to it) and, on quizzes,
`score`/`outOf`/`correct` from the opened quiz key.

### 10.1 Quiz scoring
Key per question: `{answer, points?}` (points: finite >= 0, default 1).

| type | correct when |
|---|---|
| `radioButtons`, `dropdown`, `scale`, `number` | value `===` answer (numbers) |
| `boolean` | value `===` answer |
| `date`, `time` | value `===` answer (strings) |
| `checkbox` | the set of integer indices equals the answer set; any `{other}` makes it wrong |
| `text`, `textarea`, `email`, `url` | answer is a list; non-blank value matches one after trim, lower-case and whitespace collapse |
| others | not scored |

`score` = sum of points of correct questions, `outOf` = sum over scored questions,
`correct` = `{qid: bool}`. Lower-casing follows JS `toLowerCase` for Latin-1, Latin
Extended-A and Cyrillic (the C++ mirror implements exactly that range).

### 10.2 Per-form flags (snapshot)
`mine`, `coOwner`, `mySubmitted`, `myConfirmed`, `myAnswers` (local copy),
`myReplies` (opened replies to my answer), `quiz` (opened key, creator/co-owner only),
`allowed` (whitelist), `canRespond` (trusted link, not mine, not answered, allowed, open, has
key), `canEdit`/`editUntil` (edits allowed, not yet receipted, open, inside the window),
`newResponses` (since last `markSeen`), `hidden`, `autoReceipts`, `answerDraft`, `contested`,
`pinnedCreator`, `linkMismatch`, `keyMissing`/`keycard` (phone).

A client MUST NOT seal answers when the link-pinned creator differs from the form's creator,
or when the id is contested and the link doesn't pin this creator.

### 10.3 Housekeeping (every 5 s while the node is up)
- publish drafts whose `publishAt` has passed;
- creator: close own open forms that reached `maxResponses` or passed `expiresAt`;
- creator and co-owner: if automatic receipts are on for a form, send one batch receipt for
  every unreceipted answer.

## 11. Links

`whisperbox://form?id=<formId>&by=<creator address>`. `by` pins the creator (section 10.2).
The definition itself arrives over sync; opening a link for an unknown form adds it to
"waiting for sync" and triggers a catch-up round. Legacy links `whisperbox://form?<base64 def>`
are still accepted. The desktop QR code encodes the same URI.

## 12. Core module API (`whisperbox_core`)

All methods take and return strings; results are JSON `{ok, error?, ...}`. The JS client
exposes the same names.

| method | args | notes |
|---|---|---|
| `snapshot` / `status` | | full state for the view (section 10.2) / counters |
| `createForm` | def JSON | `def.quiz` (plain) is sealed into `quizKey`; returns `formId` |
| `updateForm` | formId, def JSON | creator only |
| `closeForm` / `reopenForm` | formId | creator only; re-open refused at the cap or after `expiresAt` |
| `submitResponse` | formId, answers JSON | validates, seals, handles edits, anonymous identity, reply key |
| `confirmResponse` | formId, respondent address | creator / co-owner |
| `confirmAll` | formId | one batch receipt for every unreceipted answer |
| `setAutoReceipts` | formId, "1"/"0" | local setting |
| `getDecryptedResponses` / `exportCsv` | formId | creator / co-owner; CSV has a `score` column on quizzes. Cells are answers from untrusted respondents: one starting with `=`, `+`, `-`, `@`, tab or CR that isn't a plain number gets a leading `'`, so a spreadsheet shows it as text instead of running it as a formula |
| `addCoOwner` | formId, co-owner code (pub33 hex) | creator only; needs the form key on this device |
| `replyToResponse` | formId, confirmationId, message | creator / co-owner |
| `sendScores` | formId | one score reply per answer without any reply yet |
| `joinForm` / `importForm` | link or id / def | watch a form |
| `hideForm` / `unhideForm` / `deleteLocalForm` | formId | local only |
| `saveDraft` / `deleteDraft` / `publishDraft` | draft JSON / id / id | local drafts, optional `publishAt` |
| `saveAnswerDraft` | formId, answers JSON | local unsent answers |
| `markSeen` | formId | resets `newResponses` |
| `shareUri` / `shareQr` | formId | link / QR matrix |
| `importIdentity` / `setDeviceId` | priv hex / id | |
| `resync` | | SYNC_REQ + catch-up round |

## 13. Local state

Desktop data dir: `$WHISPERBOX_CORE_DATA`, else the first writable of `~/.whisperbox-core`
(home from the user database, never a relative path) and the host's instance folder. If the
chosen folder has no identity but another candidate does, its files are adopted. Files are
written atomically (temp file + rename); unreadable files are quarantined, not overwritten.
The folder is owner-only (0700) and every file in it 0600: it holds the private key every form
key derives from, and plaintext copies of the user's own answers. A start tightens folders that
older versions wrote 0755/0644. Nothing in it is encrypted at rest. Because the home comes from
the user database, every Basecamp profile of one account shares one identity unless
`$WHISPERBOX_CORE_DATA` says otherwise.

| file | content |
|---|---|
| `identity.json` | identity private key |
| `device_id.txt` | device id |
| `events.json` | the merged event log |
| `watched.json`, `pins.json` | forms opened from links, creator pinned by each link |
| `my_submissions.json`, `my_answers.json` | my receipt ids and plaintext copies of my answers |
| `drafts.json`, `hidden.json`, `seen.json` | drafts (incl. answer drafts), hidden forms, seen counters |

Phone (SecureStore / app storage): `wb-identity`, `wb-device`, `wb-log`, `wb-watched`,
`wb-pins`, `wb-mysubs`, `wb-myanswers`, `wb-hidden`, `wb-drafts`, `wb-seen`, `wb-fk-index` +
`wb-fk-<formId>` (Keycard-exported form keys), `wb-notify`, `wb-shared-node`.

## 14. Privacy properties

On the wire and in fleet stores:
- public: form definitions (incl. whitelists, co-owner addresses, sealed blobs' existence and
  timing), receipt ids, reply/co-owner events (who replied, to which receipt id);
- never public: answers, respondent identity, which form a blob answers, quiz answer keys,
  reply contents, form keys.

Linkability:
- receipts and replies use the respondent-chosen random `confirmationId`, which can't be
  derived from the address;
- `response.submit` carries a fresh random tag (0.4.3); the derived per-form tag it replaced
  linked a device's answers across forms for anyone who knew its device id, and every signed
  event published that (review WB-5);
- anonymous forms: the respondent address is a per-form derived identity, unlinkable to the
  real address and across forms.

Forms open to anyone (review 2026-10-22, WB-2; ADR 0019, 0.5.0): every answer is signed inside
the sealed payload, so nobody can answer in another respondent's name; an unsigned one is shown
as unverified and counts for nothing. Anyone can still generate fresh identities and answer once
with each (only a members list stops that). Close, expiry, the cap and the edit window use the
network's timestamp of the answer; before RLN is on, a sender running a modified node can still
choose that timestamp, and an answer arriving without one (BLE) is judged by its own clock.

Not protected: timing/network-level correlation; answer length (answers aren't padded); the
creator (and co-owners) see everything in an answer; a co-owner keeps access forever; there is
no forward secrecy (a leaked form key opens all of that form's answers).

## 15. Conformance fixtures

| fixture | pins |
|---|---|
| `packages/contract/test/fixtures/crypto-identities.json` | identities, addresses |
| `crypto-signed-events.json` | event signatures |
| `crypto-sealed.json` | ECIES (deterministic nonce) |
| `crypto-formkeys.json` | form keys, Keycard paths, anonymous identities, dev tags, reply keys |
| `answer-validation.json` | answer validation + quiz scoring |
| `packages/engine/test/fixtures/golden-*.json` | merge, fold, creator view over many arrival orders (contested ids, lifecycle, edits, co-owners, replies) |

An implementation conforms if it reproduces every fixture (layers 1-4 and 7 of
`scripts/test.sh`, see BUILD.md).

## 16. Compatibility

- Readers ignore unknown payload fields and fold unknown event types into `dropped`.
- New optional form fields default to off (`editableFields`); older apps simply don't
  enforce them.
- Version notes: per-form keys 0.3.0; re-open, batch receipts 0.3.2; answer edits 0.3.5;
  `form.update` 0.3.6; anonymous, co-owners 0.3.7 (desktop) / 0.3.8 (Android); replies,
  quiz 0.3.8 / 0.3.9. An older creator app cannot open answers to forms created with
  per-form keys on another device.
