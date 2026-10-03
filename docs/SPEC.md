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
| response dev tag | `"wb-" + hex(sha256(utf8(deviceId + "\|" + lc(formId))))[0..12]` |

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
`response.submit` events carry the per-form dev tag (section 2) in both `dev` and `hlc.dev`,
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
- Desktop sends each event twice: relay publish on the topic (reaches every subscriber) and
  an SDS reliable-channel send on the same id (fast path). Phone: via loam-transport (Loam
  shared node or own node).
- Delivery node: `{mode: "Core", preset: "logos.test", relay: true, entryNodes: [6 pinned logos.test fleet nodes]}`;
  `$WHISPERBOX_DELIVERY_CFG` (JSON) overrides fields. If the node already exists in the host
  (another app created it), join it, never create or start it again.
- Events are broadcast only while the node is up; local events wait in the log and go out
  through catch-up.

### 6.1 Admission (receive)
Before merging a received event:
- `form.publish`: MUST verify (section 3.2, signer == `payload.creator`).
- creator-gated types: MUST verify (signer == `payload.author`). Whether the author may do
  it is decided later, in the fold.
- `response.submit`: MUST NOT carry `pub`; MUST have `payload.encryptedPayload`.
- anything else: dropped.

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
forms' keys plus co-owned form keys opened from `form.coowner`). For each blob:

1. Trial-open with every held form key (cached per blob; retried only when the key set
   grows). Not openable means `undecrypted`. The opening key MUST be the `publicKey` of the
   form named in the plaintext, otherwise the blob is ignored. Blobs don't name their form on
   purpose: that would publish per-form answer counts.
2. Drop if stamped inside any closed span (`from <= hlc < to`) (`form-closed`), or if
   `hlc.wall > expiresAt` (`expired`).
3. Forms with a whitelist or `allowEdits`: inner signature must verify (`sig-invalid`).
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
   (`edits` only on forms that allow edits).

Closing, expiry and the cap are decided by HLC across devices, so they are only as exact as
the senders' clocks. This is accepted (ADR 0008).

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
| `getDecryptedResponses` / `exportCsv` | formId | creator / co-owner; CSV has a `score` column on quizzes |
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
- `response.submit` carries a per-form dev tag, so answers to different forms can't be
  linked by device;
- anonymous forms: the respondent address is a per-form derived identity, unlinkable to the
  real address and across forms (still one answer per person per form).

Not protected: timing/network-level correlation; the creator (and co-owners) see everything
in an answer; a co-owner keeps access forever.

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
