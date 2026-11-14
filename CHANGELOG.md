# Changelog

## 1.1.4 desktop core + studio + respond, Android vc28 (2026-11-14) - receipts v3, retry jitter

- **Receipts v3 (ADR 0027).** Each receipt carries a proof signed by the form's creator or a co-owner,
  encrypted under a secret only the respondent and the form's owners share.
  - A respondent can no longer mark its own answer as confirmed.
  - A replayed receipt can't move the edit lock.
  - Receipts can't be guessed back to their form.
  - Receipts carry decoy entries and only a 10-minute clock, and are sent per bucket.
  - 1.1.3 receipts are no longer read: answers confirmed with them show as unconfirmed until the
    creator confirms again (automatic receipts do this).
- Replies are addressed by a tag from the same secret.
- **Audit round 6:**
  - **Co-owner invitations need the creator's link (R6-5).** Without the link an invitation is listed
    as "open the form's link from its creator to accept". A fake copy of a form can no longer be
    accepted, and can't hide the real invitation.
  - A replayed receipt padded with junk is no longer kept (R6-1), and receipt handling is cached
    (R6-2).
  - Oversized receipt ids are ignored (R6-3).
  - Show-count forms count only named receipts (R6-6).
  - Receipt re-sends are capped (R6-9).
- **Receipts wait 1-5 minutes** in a per-bucket outbox, then go out as one event with at least 8
  entries. A respondent's retry gets the same receipt again, byte-identical (anoncomms' review of v3).
- **Audit round 7:**
  - a proof can't confirm a second answer that reuses a reply key (R7-1);
  - receipt handling is incremental (R7-2);
  - receipt times are fixed-length (R7-4).
- **Audit round 8:**
  - receipts waiting for a form you left are dropped (R8-1);
  - the answer clock survives a restart (R8-2);
  - a tighter network-time window (R8-3);
  - the outbox is saved in batches and sealed with a passphrase (R8-5/R8-6).
- **No ASK any more (ADR 0028, F1/F5).** A missing form arrives with the Store pull or the creator's
  hourly re-publish, which now has a random ±25% interval. Answers carry only a 10-minute clock (F3).
- **Answer retries (ADR 0028, F4).** Retries happen at random times (±30%), and on anonymous forms
  they stop after about an hour.

## 1.1.3 desktop core + studio + respond, Android vc27 (2026-11-14) - blinded receipts, audit round 5

- **Receipts are blinded (ADR 0026):** a receipt names no form, no author and no device, and isn't signed.
  It carries only tags that the respondent and the form's owners can recognise. Bystanders, Stores and
  relays can't tell which form got receipts, how many, or whether its creator is online. Replies are
  addressed the same way.
- Forms that show respondents how many answers came in keep public, signed receipts. The builder now
  says so.
- **Clean break for receipts:** 1.1.2 and older don't understand the new receipts, so an older
  respondent keeps re-sending its answer. Upgrade creators and respondents together.
- Co-owner invitations: shown and acceptable only from the form's known creator, once the form has
  arrived. A stranger's grant no longer hides a real invitation. A form someone else also published
  needs the creator's link to accept (audit R5-1, R5-2).
- An answer's network time must agree with its own timestamp (within 10 minutes). The earliest
  agreeing time wins, so a dishonest Store can't push an honest answer past a close (R5-3).
- With first-seen times lost too, at most 2,000 unplaceable answers are kept (R5-4).

## 1.1.2 desktop core + studio + respond, Android vc26 (2026-11-13) - audit round 4

- Accepting a co-owner invitation never makes the inviter "the creator" of a form; invitations from more
  than one sender for the same form aren't shown.
- An answer's time is fixed by the first evidence of it: a live replay can't re-date what a Store dated.
- If the record of my own answers is lost, my answers still survive the clean-up, however many strangers'
  answers an older version stored.
- Four audit rounds of wire v2 are done; remaining limits are listed in ADR 0024 (amendment 4).

## 1.1.1 desktop core + studio + respond, Android vc25 (2026-11-13) - audit round 3

- Co-owner invitations count only when the form's creator sent them (a fake one is never shown);
  a declined invitation can still be accepted; accepting pins the inviter as the form's creator.
- A form whose creator isn't known (opened by its bare id) keeps only its publishes and invitations.
- A co-owner's receipt that arrives before its grant is kept.
- Times: a Store can't date an answer in the future or before the asked window (phone too); the first
  live time is final. The second-Store check is retried and survives a restart.
- Store replies: oversized ones refused before parsing; duplicates count towards the work budget.
- If the record of my own answers is behind, at most 2,000 unplaceable answers are kept, not the bucket.

## 1.1.0 desktop core + studio + respond, Android vc24 (2026-11-13) - after two audit rounds of wire v2

Wire v2 was audited twice (proteus/auditor, 2026-11-13: 13 + 15 findings); ADR 0024 amendments.
Wire-compatible with 1.0.0.

- **A node keeps only its own forms and answers** (Václav): forms it created, co-owns, opened,
  answered, drafted or hid, and answers it sent or can open. Everything else in its bucket is dropped
  on arrival; old data is pruned on the first start; removing a form drops its data.
- **Co-owner grants are invitations:** Accept / Decline in the studio sidebar and on the phone's home
  screen; nothing of the form is kept until accepted; Leave on a co-owned form.
- **Receipts are minimal:** sent on their own, coalesced per form, not in the hourly form state; a
  retried answer gets its one receipt again.
- **Deadlines use the network's time:** a Store-delivered answer is judged by the latest time any of
  two Store nodes reports; a time seen live is never changed by a Store.
- **Nothing too big to deliver:** forms and answers over ~78 KB are refused with a reason (Delivery
  caps a message at 150 KiB, base64'd twice).
- Store replies are untrusted (asked topics only, 100 a page, 5,000 events a pull); signed events must
  come from someone allowed to write them; 20,000 answers kept per form; ASKs budgeted, never from
  Store; a squatted form id no longer stops the ASK; re-subscribe after a reconnect; failed sends are
  retried; the phone counts text in UTF-8 bytes like the desktop.

## 1.0.0 desktop core + studio + respond (2026-11-12) - wire v2: Store first, creator served (ADR 0024)

A clean break with 0.x on the wire (events, the fold and local data carry over). On 2026-11-12 one fresh
node made every WhisperBox on `logos.test` re-send everything at once (v1's global topic + catch-up rounds
+ peers serving each other); with RLN enforced that would also eat every node's message budget.

- **Bucket topics:** each form lives on one of 16 topics (`/whisperbox/2/form-<b>/proto`); a node joins
  only its forms' buckets - strangers' forms and answers never reach it.
- **Store, not peers:** a node pulls its buckets from Store on start, on reconnect, when it opens a form
  and every 15 min. No catch-up rounds, no SYNC_REQ, nobody serves anybody. An idle node sends nothing.
- **Creator served:** the creator re-publishes each open form's whole state (definition, edits, receipts,
  replies) every hour, and answers an ASK when a respondent can't find a form in Store. Respondents
  never answer ASKs.
- **Answers until the receipt:** sent once, then every 10 min for an hour, hourly for 4 h, every 6 h, for
  14 days - so a creator offline longer than Store keeps things still gets them.
- **RLN budget:** at most 10 messages per 600 s epoch (of the node's 100), the most urgent first (answer,
  receipt, form change, ASK, re-publish, retry).
- **Edge:** without Loam the core runs delivery as a light node (no relaying).
- Store peers: `StoreNodes` node info when Delivery has it, else the fleet - upstream ask
  logos-co/logos-delivery-module#187. Store retention measured ~48 h; designed for 1-2 h.
- Tests: e2e 417 (incl. a v2 section: idle silence, Store pull, hourly re-publish, ASK, retries until the
  receipt, budget priorities); JS wire-v2 tests; JS phone <-> C++ desktop interop on v2 incl. a fresh
  phone getting forms by ASK from a C++ and a JS creator.

## 0.8.0 desktop core + studio + respond (2026-11-12) - form files, feedback from other apps (ADR 0023)

- **Export** (studio, your forms): saves `whisperbox-form-<id>.json` to Downloads - the creator-signed
  form, no keys.
- **Other Basecamp apps** ship that file and call
  `logos.request("whisperbox.respond", {form: fileText}, cb)`: WhisperBox checks the signature, shows
  the form, sends the answer, and replies `submitted: true` when an answer was sent, `false` when the
  person left. Links work as before; the reply now waits for the answer instead of coming on open.
  Basecamp offers to install WhisperBox when an app asks and it isn't there.
- Core `exportForm` / `importFormFile` (+ the JS client for Android): a file is checked event by event
  like the network's; a tampered file or one carrying anything but the creator's form is refused.
- `examples/feedback-demo`: a minimal app with a Send feedback button.

## 0.7.0 desktop core + studio + respond (2026-11-11) - several answers per person (ADR 0022)

- **Protocol:** a form can take several answers from one person: `maxPerRespondent` = N, or 0 for no
  limit (default 1, unchanged). Each answer is its own entry with its own receipt (keyed by the sealed
  receipt id), numbered per person; the per-person cap comes before the form's. Signed answers only;
  not combinable with edits. Both engines (C++ + JS) reproduce a new golden scenario.
- **Studio:** "Let each person send several answers (up to N)" in the form settings; receipts per
  answer; "their answer #N"; a line with how many answers each person sent and how many you received
  (for rewards: count received answers).
- **Respond / answering view:** after sending, an empty form for the next answer; "you've sent N
  answers (M received)"; My forms shows it per form.
- Older WhisperBox versions see only a person's first answer to such a form: publish these once
  people run 0.7.0. Android follows.

## 0.6.1 core (2026-11-11) - one WhisperBox per Basecamp profile

- **The identity follows `--user-dir`.** Two Basecamp instances under one OS user shared one identity
  and one set of files: the core kept everything in `~/.whisperbox-core`, taking home from the user
  database. So a second instance saw every form as "your own" and couldn't answer it, and both wrote
  the same files. In Basecamp the data now lives in Basecamp's folder for the module
  (`<user-dir>/module_data/whisperbox_core/<id>/`), which survives restarts, upgrades and uninstall.
- **Migration:** only the default profile (no `--user-dir`) copies the old `~/.whisperbox-core`, once,
  and marks it `CLAIMED-BY.txt`; the old folder stays as a backup. Other profiles get their own
  identity. Headless (logosctl) and `WHISPERBOX_CORE_DATA` are unchanged.
- Tests: e2e 370 (profiles: takeover once, restart, own identity per `--user-dir`, no second
  takeover, re-takeover after `module_data` is wiped, headless unchanged).

## 0.6.1 studio + respond views (2026-11-11) - respond module: My forms, Cancel, own-form message

Core 0.6.0 at the time. Found testing 0.6.0 from lan03 (Václav).
- **Own form showed an empty box:** opening your own form's link in the respond module showed the title
  and one empty, uneditable box. A creator can't answer their own form, and the "can't answer" banner
  had no text for that case (the studio never shows the answering view for your own forms). It now
  says so and points to the studio; an empty banner is never drawn.
- **respond module, My forms:** the home screen lists the forms opened or answered here (with their
  state: not answered, saved, answered, received, closed, still arriving); click one to open it.
- **Back and Cancel:** "My forms" leaves a form and keeps half-filled answers; Cancel leaves it and
  forgets them. A form still arriving can be left too.
- Studio renders pixel-identical to 0.6.0.

## 0.6.0 desktop core + studio + NEW respond module (2026-11-10) - Loam optional, answer a form from a link

ADR 0021. Android unchanged.
- **whisperbox_respond (new module):** answer one form, opened from a link or by another app with the
  intent `whisperbox.respond {link}`; paste a link when opened directly. Nothing to create or manage.
  It uses the same core and the same answering component as the studio.
- **Loam is optional:** `whisperbox_core` now requires only `delivery_module`; `loam_core` is optional.
  With Loam installed nothing changes (it is used exactly as before). Without it the core talks to
  `delivery_module` directly through Loam's shared wire header (loam_core 0.7.4), on the same network
  and wire, and joins a delivery node another module already started.
- **Studio:** the answering UI is now `FormRespond.qml`, shared with the respond module; every studio
  screen renders pixel-identical. Views moved under `qml/` (the builder only packages the entry file
  when it sits at the package root).
- Tests: ALL 8 LAYERS GREEN (e2e 356, incl. Loam peer <-> direct peer and adopting a running node).
  Live on logos.test: a delivery_module-only build <-> the published 0.5.5 on loam_core 0.7.4, forms and
  answers both ways.

## 0.5.5 desktop core + view, Android 0.5.5 (2026-11-05) - open-review fixes, round 5

From the open-review report on 0.5.4 (https://or.vpavlin.xyz/whisperbox-logos-3915b2592feb-full/),
which confirmed the published linux-amd64 package now matches a rebuild. Tests: the e2e
"open-review 2026-11-03" block, `packages/client/test/round5.test.mjs` and the QML scenarios
`detail-*`, `locked`, `import-ask`:
- **FR-1 (High):** a signed event replaced by an earlier copy is charged for its size against the
  log cap (a small event replaced by a large one used to grow the log past the cap); a held answer
  is never replaced.
- **FR-2 (High):** the snapshot, which is also the `stateChanged` event any Basecamp module can
  receive, no longer carries decrypted content. The view gets answers, my answers, my replies, quiz
  keys and answer drafts from the new `formDetail(formId)` for the form it shows. A module calling
  the methods directly still gets what the user would (Basecamp gives no caller identity).
- **FR-5 (High):** the log is no longer rewritten on every flush: events are appended to
  `events.journal`, folded into `events.json` when the journal outgrows the base.
- **FR-13 (High):** an optional passphrase (Identity) seals the key and the saved answers
  (`my_answers.json`, `drafts.json`) on disk; WhisperBox then starts locked and asks for it. Off by
  default.
- **FR-3 (Medium):** an answer with no network time that this device first saw while the form was
  closed doesn't count, whatever time it claims. Close-at dates still use the answer's own time
  when there is no network time (see SPEC).
- **FR-4 (Medium):** importing an identity keeps the previous key as `identity.json.prev` and asks
  once more, naming the address it replaces.
- **FR-11 (Medium):** pending events for unknown forms are counted in the snapshot, not listed.
- **FR-12 (Medium):** quiz scores are computed for the form being viewed only, with questions
  parsed once and each answer's score cached.
- **FR-6 (Low):** the event budget is taken before a signature is verified, and a duplicate isn't
  verified again.
- **FR-7 (Low):** automatic receipts only on your own forms; "Remove" keeps your own answers; a
  deleted draft goes to a trash (the last 20).
- **FR-8 (Low):** documented: `formSummary` answers for any form on the topic (public data).
- **FR-9 (Low):** "Delete draft" asks once more; opening the same template again reuses its draft;
  the Import warning no longer mentions a missing export.
- **FR-10 (Low):** this entry and the code comments describe what changed; the tests above check it.
- **FR-14 (Low):** drafts (200, 16 MiB), answer drafts (1000), opened and hidden forms (10,000) are
  bounded, and answer drafts are saved once per flush, not per keystroke.

## 0.5.4 desktop core + view, Android 0.5.4 (2026-11-03) - open-review fixes, round 4

From the open-review report on 0.5.3 (https://or.vpavlin.xyz/whisperbox-logos-5727d23c4fad-full/).
Each fix has a regression test in the e2e "open-review 2026-11-02" block,
`packages/client/test/round4.test.mjs` or `whisperbox_core/test/rbsr_parity_test.cpp`:
- **FR-1 (Critical):** the published 0.5.3 linux-amd64 core did not reproduce from source. It was
  built through the root flake, which forced an older builder (`afe4430`) onto the core. The root
  flake now keeps each module's own pin (0.3.1, `16e2f6b`); releases build each package from its
  own flake. A rebuild of 0.5.3 from `whisperbox_core/` matched the reviewer's rebuild exactly.
  0.5.4's linux-amd64 build comes from the pinned builder like arm64 and macOS.
- **FR-2, FR-5, FR-7 (High), a peer could freeze every desktop:**
  - signatures are verified once, at admission and load; every snapshot re-verified the whole log;
  - the fold and the creator view are cached until the log, pins or identity change;
  - the fold indexes forms, deferred events, receipts and replies; it was quadratic: 50,000 forms
    took 49 s, now 50,000 forms plus 50,000 answers take about 1 s;
  - the sealed pool isn't copied into the fold any more;
  - the snapshot carries only the forms the device shows;
  - signed events from the network have a budget (600 at once, then 10 a second).
- **FR-3 (High):** the creator view keeps a running count for the answer cap and indexes forms.
  20,000 answers took 54 s; now 37 ms.
- **FR-4 (High):** catch-up frames have a budget (120 a minute) and are answered from a sorted id
  index with cached hashes. Ranges per frame are capped at 16 with increasing bounds; serving is
  capped at 100 events and "need" lists at 500 ids. Messages on the wire are unchanged (checked
  against the vendored loam-sync responder on 300 random exchanges).
- **FR-6 (High):** a duplicate is recognised by its key without scanning the log, every copy of an
  answer costs budget, and network times are saved once per burst.
- **FR-8 (Medium):** loam_core callbacks reach the module only through a lifetime guard. A callback
  after unload touched freed memory (ASan); the e2e test now runs clean under AddressSanitizer.
- **FR-9 (Medium):** a receipt id over 128 bytes is treated as absent, and no local event peers
  would refuse is stored or sent.
- **FR-10 (Medium):** an answer over the event size cap is refused with an error instead of being
  kept as "sent".
- **FR-11 (Low):** form ids must fit the share link (`x&y` was published, but its link opened
  form `x`).
- **FR-12 (Low):** the inner signature text uses JavaScript's number format on the desktop too. A
  phone answer holding `1e-7` failed to verify on the desktop.
- **FR-13 (Low):** desktop and phone have "Remove" for forms you didn't make. It drops the creator
  pin, so the right link can be opened after a wrong one.
- **FR-14 (Low):** a failed transport start is retried (5 s, backing off to a minute); a failed join
  is retried too.
- **Not changed:** a copy received again can still move an answer's network time earlier, within
  the 5-minute window.
- **Behaviour changes:** the snapshot no longer lists forms the device never opened, and catch-up
  frames with more than 16 ranges are ignored (WhisperBox sends 8).

## 0.5.3 desktop core + view, Android 0.5.3 (2026-11-02) - open-review fixes, round 3

From the open-review report on 0.5.2 (https://or.vpavlin.xyz/whisperbox-logos-42609fcc4878/). Each fix
is in the desktop core and the phone client alike, with a regression test in the e2e "open-review
2026-11-01" block and in `packages/client/test/round3.test.mjs`:
- **FR-1 (High):** a form made before per-form keys (its key is the creator's identity key) can't
  get a co-owner any more. Adding one sealed the identity key to the co-owner, who could then sign
  as the creator. Duplicate such a form to share it.
- **FR-2 (High):** decrypted answer rows are checked: `questionId` a string of 1-128 bytes, the value
  null, bool, number, string, `{other}` or a list of those. Malformed rows are dropped. CSV export
  returns an error instead of throwing on a mistyped field.
- **FR-3 (High):**
  - new answers from the network have a node-wide budget (600 at once, then 10 a second);
  - the log stops taking answers at 50,000 or 256 MiB (signed events have 32 MiB more);
  - the snapshot sent to the view carries a count of the sealed answers, not the answers (it
    grew by every blob);
  - the decrypt cache is bounded;
  - a burst of received events is saved and published once every 250 ms, not once per event.
- **FR-5 (Medium):** the first link's creator stays pinned. A second link naming another creator
  for the same form id is refused. Removing the form from the device drops the pin.
- **FR-6 (Medium):** a network timestamp counts only within 5 minutes of the receiver's clock,
  in either direction. An older one (a sender's node stamping 2001, or a store copy fetched later)
  is treated as absent: the answer's time shows as unverified.
- **FR-7 (Medium):** a scale question needs whole-number `min` <= `max`, at most 100 apart. Peers
  refuse wider ones; the views draw at most 101 steps either way.
- **FR-8 (Medium):** `confirmResponse` gives receipts only to signed answers. An unsigned answer
  claiming someone's address used to take their receipt. Unsigned (pre-0.5.0) answers get no
  receipt by address.
- **FR-9 (Low):** importing another identity clears the old one's own answers, receipts, private
  replies, "seen" counts and key caches. The files are copied to `*.prev` first.
- **FR-10 (Low):** a sealed answer must be lower-case hex of whole bytes: an upper-case copy was a
  second event that opened to the same answer.
- **FR-11 (Low):** every file the core reads back (identity, pins, drafts, answers) gets the depth
  and size limit. The device id is 1-64 of `[A-Za-z0-9_-]`.
- **FR-14, FR-16 (Low):** a failing random-number generator is an error, not zero bytes. Base64
  uses an unsigned, masked accumulator.
- **Not changed (documented):**
  - FR-4: co-installed modules are still trusted (SPEC § trust boundary);
  - FR-12: the four advisories are in Expo's build tooling, not in the app;
  - FR-13: the identity and the saved answers are stored unencrypted, 0600 (README);
  - FR-15: comments now say what changed; the tests above are the evidence.
- **Breaking:**
  - a legacy-key form can't get co-owners;
  - an unsigned answer can't be confirmed;
  - a second link with a different creator is refused.

## 0.5.2 desktop core + view, Android 0.5.2 (2026-10-30) - open-review re-review fixes

From the open-review report on 0.5.1 (https://or.vpavlin.xyz/whisperbox-logos-ea85ebafb8c1/), in
the desktop core and the phone client alike:
- **FR-1 (High):** what's decrypted (answers, replies, quiz keys), links and caller arguments are
  parsed with a depth and size limit. An answer sealed to a form's public key with 50,000 nested
  arrays inside crashed the creator's core.
- **FR-2 (Medium):** numbers from peers are bounded at admission (`maxResponses`,
  `editWindowMinutes`, `expiresAt`, `createdAt`, question `min`/`max`), and casts saturate. A
  sealed `submittedAt` is only compared when it's plausible.
- **FR-3 (Medium):** answers go only to a creator a link or QR code named. A form known only by
  its id can be viewed but not answered ("open the creator's link"). Whoever published under the
  id first used to receive the answers.
- **FR-4 (Medium):** the legacy SYNC_REQ reseed is limited to once a minute, with a
  device-id-shaped `from`, and the served-events map is bounded. Per-sender ingest limits and an
  append-only log are still to do.
- **FR-5, FR-6, FR-7, FR-8, FR-9 (Low):**
  - local forms pass the shape check peers apply;
  - `form.publish` is verified at load;
  - CI actions and the builder flake are pinned to commits;
  - the robustness claims in comments and the 0.5.1 notes are qualified;
  - the SPEC says co-installed modules are trusted (the host gives no caller identity).
- **Breaking for respondents:** a form opened by typing its bare id can't be answered any more.
  Open it from the creator's link or QR code.

## 0.5.1 desktop core + view, Android 0.5.1 (2026-10-29) - open-review fixes

Fixes from the open-review report on 0.5.0 (https://or.vpavlin.xyz/whisperbox-logos-302a134f8dbe/),
the same in the desktop core and the phone client:
- **FR-1 (High):** a frame over 1 MiB or JSON nested more than 32 deep is refused before it is
  parsed. One deeply nested frame used to crash the core before any signature was checked. The
  canonical-JSON signer also stops at depth 64. (This covers the network envelope only: the
  decrypted content got the same limit in 0.5.2.)
- **FR-2 (High):** an HLC counter above 2^30 is refused and never adopted. A local counter at the
  bound carries into the next millisecond instead of overflowing.
- **FR-3 (High):** serving events for other peers (RBSR, legacy SYNC_REQ) is bounded: 100 events
  per incoming frame, an event served in the last 2 s isn't served again, and at most 300 a
  minute. A 40-byte frame used to trigger a full-log broadcast.
- **FR-4 (Medium):** a form's publicKey and a co-owner code must be points on secp256k1, and ECDH
  throws on an invalid point. An invalid key used to give an all-zero secret, so anyone could read
  the answers.
- **FR-5 (Medium):** the CSV export has `verified` and `timeVerified` columns. Unverified answers
  get no automatic receipts and don't count towards the auto-close at the answer limit.
- **FR-6 (Medium):** a whole event is at most 256 KiB.
- **FR-7, FR-8, FR-9, FR-12 (Low):**
  - signed event types are verified again when a log loads;
  - JSON-taking methods return an error for mistyped fields instead of throwing;
  - the README describes the 0.5.0 model;
  - the e2e harness reports FAIL instead of aborting.
- Not changed yet: FR-10 (pinning CI actions and the builder flake to commits) and FR-11 (mobile
  lockfile advisories in build tooling).

## 0.5.0 desktop core + view (2026-10-29) - every answer is signed

A protocol change: creators should update first. Answers from 0.4.x clients still arrive, marked
"unverified".

- **Every answer is signed** inside the sealed payload by the respondent it names, on every form
  (ADR 0019). On forms open to anyone an unsigned answer (an older client, or someone claiming
  another respondent's address) is kept and shown as unverified: it takes no respondent slot,
  doesn't count towards the answer limit and can't edit anything. Before 0.5.0 an unsigned answer
  in someone's name, stamped earlier, replaced theirs (review 2026-10-22, WB-2).
- **Deadlines use the network's timestamp**: close, re-open, the close-at date, the answer limit
  and the edit window go by the earliest Logos Delivery timestamp seen for an answer, not the
  sender's clock. An answer without one (BLE) keeps its own time and is marked "time not
  verified"; a sender's clock more than 5 minutes off is shown. Until RLN is on, the network time
  is only as honest as the sender's node.
- **Review 2026-10-22 fixes** (audited):
  - a hostile peer's malformed frames, far-future clocks and poisoned logs can't crash, stall or
    time-shift a node;
  - answer tags are random, so answers can't be linked across forms;
  - the data folder is private (0700/0600);
  - CSV export neutralises formula cells;
  - the status follows the transport after connect;
  - links that can't be valid are refused.
- Docs: SPEC (admission, answer time, what isn't protected), ADRs 0003/0008/0010/0011 updates,
  ADR 0019.

## 0.4.2 desktop view (2026-10-10) - macOS

- The view is rebuilt against core 0.4.2's interface and ships for darwin-arm64 (Apple
  Silicon) as well as linux-amd64 and linux-arm64. No functional change.

## 0.4.2 desktop core / Android 0.4.1 (2026-10-10) - usable from other apps

- **`formSummary(formId)`**: title, status, receipts and (for the creator or a co-owner)
  the answer count, new answers and the last answer time, for a card in another app.
- **The protocol is a library**: `packages/` is now `vpavlin/whisperbox-sdk` (a submodule at
  the same path) with form templates (booking, crew, guest list, feedback) and a React
  Native adapter whose app id and transport the host app sets (ADR 0018). The Android app
  uses the adapter; its behaviour is unchanged (Android 0.4.1 is that refactor).

## Android 0.3.10 (2026-10-03) - no Google services

- **Removed all Google code from the APK.** `expo-notifications` bundled Firebase Cloud
  Messaging + Installations and asked for `c2dm.RECEIVE`, the Play install referrer, boot /
  wake and ~17 launcher-badge permissions; `expo-camera`'s QR scanner is Google ML Kit +
  Play services code scanner (Play services, Firebase components / encoders). Neither was
  needed: WhisperBox has no push server.
- Notifications are now posted locally by a ~70-line module (`native/localnotify`); tapping
  one opens the form via its `whisperbox://` link.
- QR codes are read with ZXing (`native/qrscan`, zxing-android-embedded, Apache-2.0).
- Permissions are now: internet, camera, NFC, notifications, vibrate, Loam bind. APK 39.7 ->
  33.4 MB. `scripts/release/release.sh` refuses any APK with Firebase / Play services / ML Kit
  code or push / referrer / badge permissions, and always prebuilds with `--clean`.
- Docs: `docs/SPEC.md`, `docs/BUILD.md`, ADRs 0002-0017; release scripts in `scripts/release/`.

## 0.3.8 desktop / 0.3.9 Android (2026-10-03) - quizzes, private replies

- **Private replies**: every answer now carries a one-off reply key (derived from the
  respondent's identity per form + receipt id, so nothing new is stored and it can't be
  linked to them). The creator or a co-owner can reply to one answer; only that respondent
  can read it. Wire: `response.reply` {formId, author, to: receipt id, sealed}, creator /
  co-owner gated like receipts.
- **Quiz mode**: mark the right answer per question (choice, yes/no, checkbox set, accepted
  spellings for text - trimmed + case-insensitive, numbers) with optional points. The answer
  key is sealed to the form key (`quizKey`), so respondents and relays can't read it.
  Creator / co-owners see scores (table column, one-by-one ✓/✗, average, CSV "score"
  column) and "Send scores" delivers each person their score privately, once.
- Respondents see "From the creator - only you can read this" with their score, per-question
  ✓/✗ and messages; Android notifies when a reply or score arrives.
- Fix: desktop showed the respondent view under the creator view for co-owned forms.
- Shared fixtures: scoring rules (JS == C++, incl. Czech / Cyrillic case folding), reply key
  vectors, golden-lifecycle reply events (creator + co-owner accepted, stranger dropped).

## 0.3.7 desktop / 0.3.8 Android (2026-10-03) - anonymous forms, co-owners

- **Anonymous forms**: respondents answer under a one-off identity derived per form from
  their key - one answer per person, but the creator can't link it to their address or
  across forms. Not combinable with members-only.
- **Privacy fix (all forms)**: answer events carried the respondent's device id in plain
  text, so anyone could link answers to different forms by device. They now carry a
  per-form tag.
- **Co-owners**: the creator seals the form's key to a colleague's co-owner code (shown
  under Identity); co-owners read every answer, export CSV and send receipts (also
  automatically); closing / re-opening / editing stay with the creator. Access can't be
  revoked; the co-owner list (addresses) is public. Wire: `form.coowner`; pinned by
  golden-lifecycle (co-owner receipt accepted, co-owner close rejected, co-owner view).

## 0.3.6 desktop / 0.3.7 Android (2026-10-03) - edit after publishing

- **Edit a published form** ("Edit" on your form): title, description, questions and
  settings; everyone gets the new version (a creator-signed `form.update`, the latest wins;
  updates from anyone else are dropped). Existing questions keep their ids, so answers
  already sent stay attached even when questions are inserted or reordered. Respondents
  see "updated <time>"; new rules (e.g. a changed limit) apply to new answers.
- Copying a question in the builder now always creates a new question id.

## 0.3.5 desktop / 0.3.6 Android (2026-10-03) - answer edits

- **Respondents can edit their answer** on forms that allow it: for 15 minutes after first
  sending it, until the creator sends a receipt, while the form is open. Edits keep the
  original receipt id and are signed inside the sealed answer, so nobody can "edit"
  someone else's answer. The creator sees one response, marked "edited"; edits don't
  count against the answer limit. Wire: form `allowEdits` / `editWindowMinutes`, fold
  `receiptHlc`; pinned by golden-lifecycle.json (edit inside the window / too late /
  after the receipt / unsigned / signed by someone else).
- Fix (core): a decrypted answer with a null field could throw out of the creator view
  (a malicious respondent could break the creator's snapshot); such answers are dropped.

## 0.3.4 desktop / 0.3.5 Android (2026-10-02) - question types, polish, new answers

- **New question types**: dropdown, linear scale (numbers or stars, end labels), number
  (min / max), date, time, email, link; "Other: ___" on choice questions; help text.
  One set of answer rules (contract/src/answers.mjs = C++ validateAnswer, shared fixture).
- **Polish**: thank-you message, shuffle questions / options (same order on both apps),
  progress line, Preview, 5 templates, "By question" view, Summary for every type.
- **New answers**: "N new" badges per form and on My forms (seen counts kept per device;
  opening a form clears it). Android notifications while the app runs in the background
  ("3 new answers - tap to open"; never the answers themselves), switch under Identity.

## 0.3.3 desktop / 0.3.4 Android (2026-10-02) - fixes

- **WhisperBox connects when another Logos app already started the network node.**
  Basecamp runs one `delivery_module` for all apps; a second `createNode` answers
  "Context already initialized", which WhisperBox reported as an error and retried
  forever. It now joins the running node (and never starts it twice). E2E covers it.
- **Desktop: Save draft works.** The save callback read the core's raw reply as an object,
  so every save looked failed: no feedback, no draft id kept, and autosave created a new
  draft every 2.5 s. Drafts section gets "clear all" for the duplicates this left.
- **Android: unsent answers are kept.** They were restored from a stale snapshot and a
  save pending when leaving the form was cancelled; now read from the client and flushed
  on leave. Desktop flushes before switching forms.

## 0.3.2 desktop / 0.3.3 Android (2026-10-02) - responses viewer, receipts, lifecycle, drafts

- **Responses in three modes**: Summary (bars per choice / yes-no question, recent text
  answers), Table (one row per response, search, click to open), One by one (prev/next,
  jump to a number, number strip; arrow / Home / End keys on desktop).
- **Send all receipts** in one go (one event per 100 receipts), and **automatic receipts**
  per form. Respondent apps can show the receipt count ("N responses received so far")
  when the form enables it.
- **Yes / No** question type.
- **Close, re-open, auto-close**: re-open a closed form (answers sealed while it was closed
  stay rejected); close automatically after N answers (the first N in time order count,
  identically everywhere) or at a date.
- **Drafts and scheduled publishing**: forms autosave as drafts (Drafts section); publish
  now or at a time (goes out when the app is running then). Half-filled answers autosave
  and come back after a crash or restart.
- **Duplicate** any form into a new draft; move / copy questions in the builder.
- Wire: `form.reopen`, `maxResponses`, `showResponseCount`, batch receipts
  (`confirmationIds[]`), `boolean` answers; pinned by golden-lifecycle.json (JS = C++).

## 0.3.1 desktop / 0.3.2 Android (2026-10-02)

- **Hide forms** (both apps): Hide/Unhide on any form; hidden forms move to a collapsed
  "Hidden" section. Local only - nothing is deleted from the shared log, your keys and
  answers stay. Core: `hideForm` / `unhideForm`, `snapshot.hidden`, `hidden.json`.
- **See your own answers** on forms you answered. The sent answers are sealed to the
  creator, so each app keeps a private local copy at submit (`my_answers.json` /
  `wb-myanswers`); answers sent by older versions show a note instead.
- **Identity kept across restarts** (desktop): the data folder is never a relative path.
- **No public listing**: only your forms, answered forms and forms opened from a link.
- `hub/fill-form`: answer a form N times from fresh identities (test data).

## Unreleased - per-form keys, Keycard (Android 0.3.0)

- **Android: forms sealed with your Keycard.** "Answers open with: My Keycard" exports the
  form's own key from the card's EIP-1581 subtree with one tap at publish; the PIN is used
  for that tap only. After a reinstall, "Unlock answers with Keycard" restores every
  missing form key in one tap. Identity screen: default for new forms + pairing password.
  Tested against the real Keycard applet (3.1.2 and 4.0) in a simulator, incl. pulling
  the card away at every command. Not yet tapped with a physical card.

- **Each form is sealed to its own key** (`form.publicKey`), derived from the identity
  with HKDF (`whisperbox-formkey-v1`), no longer the identity key itself. A leaked
  form key opens one form only - the groundwork for Keycard-exported form keys and
  validator hubs (docs/adr/0001-per-form-keys.md). Respondents are unchanged; forms
  created before keep opening with the identity key. Creators trial-open blobs
  against their form keys (cached); a key must match the form the answer claims.
- Golden vectors shared by JS reference, portable JS and C++; E2E 88/88.

## 0.2.0 (2026-10-01) - core + view in lockstep

Review of everything shipped so far found several bugs that hit every install;
this release fixes them and finishes the Phase 6 feature set. Both packages
(`whisperbox_core`, `whisperbox`) MUST be updated together.

### Core (`whisperbox_core`)
- **Fix: creator snapshot crashed once a response was decrypted.** The confirmed-
  flag hash built its byte buffer from two *different* temporary strings
  (`Bytes((a+b).begin(), (a+b).end())`), which is undefined behaviour and in
  practice threw `std::length_error` from `snapshot()` / `confirmResponse()`.
- **Fix: incremental merge inserted events in reverse HLC order.** `mergeOne`
  walked back while `prev < e`, so every newer event landed at the FRONT of the
  log. Fold order (e.g. "earliest response per respondent wins") could differ
  between replicas. Existing logs are re-sorted on load.
- **Fix: batch merge comparator.** `mergeWhisperbox` passed the 3-way
  `totalOrder` (-1/0/1) straight to `std::sort` (invalid strict-weak-order, UB).
- **Fix: every install shared the device id `whisperbox-core`.** It was never
  loaded from `device_id.txt`, so all peers ignored each other's `SYNC_REQ` as
  self-sent (cold start waited for the 60 s re-seed) and SDS saw identical
  sender ids. Now a random `wb-<hex>` id is generated once and persisted.
- **Fix: opening a share link before sync left the form empty forever.**
  `importForm` adopted an unsigned placeholder under the canonical event id,
  which the creator's signed event could never replace. It now only watches
  the id and asks peers to sync; old placeholders are dropped on load.
- **Privacy: receipts are no longer linkable to respondents.** The public
  confirmation id was `sha256(formId|respondentAddress)`, so anyone could test
  whether a given address had answered. Respondents now seal a random
  `confirmationId` inside their response and keep it locally. Legacy
  responses still confirm via the old hash.
- **Whitelist `addresses` is enforced.** Previously only the inner signature
  was checked; now the creator also drops responses from unlisted addresses
  (`not-whitelisted`). The respondent's core refuses up front.
- Respondent state in the snapshot: each form carries `mine`, `mySubmitted`,
  `myConfirmed`, `allowed`, `canRespond`; `pendingForms` lists imported ids
  whose definition hasn't synced yet.
- `submitResponse` rejects double submissions, missing required answers,
  unsupported whitelist types and forms whose key hasn't synced.
- `exportCsv`: proper columns (no trailing empty column), ISO timestamps, a
  `confirmed` column, choice answers rendered as option text.

- **Catch-up via loam-sync RBSR.** The 60 s whole-log re-broadcast is gone:
  peers exchange one bounded fingerprint message per round (at 3 s, 10 s,
  25 s after connect, then every 60 s) and serve only the exact delta.
  0.1.x peers still get the full log when they ask (unflagged SYNC_REQ).
- **Security: event-id squatting.** Ids are deterministic and not tied to the
  author, so a forged `close:<form>` (or a back-dated, validly signed
  `form:<id>` from someone else) could shadow the genuine event - in the
  squatting case respondents would seal answers to the attacker. Signed
  events now dedup by (id, signer); a form id published by two creators is
  marked `contested`; each device shows its own copy, else the creator pinned
  by the share link, else the first, and refuses to send answers to a
  contested or link-mismatched form. Share links now carry the creator
  (`whisperbox://form?id=…&by=0x…`); old id-only links still open.

### View (`whisperbox`)
- Rewired to the real core API (0.1.3 called `submitResponse` with one
  argument and read non-existent fields, so submitting and the creator's
  response list did not work; it also failed the render harness).
- All four question types in the builder and the answer view (short text,
  paragraph, single/multiple choice), required flag, options editor, and an
  optional "only listed addresses" restriction.
- Creator: response cards with question text and option labels, "Send
  receipt", "Close form", CSV export dialog with real clipboard copy.
- Respondent: sent / receipt-received / closed / not-on-the-list states.
- Share dialog with the short `whisperbox://form?id=` link + a scannable QR,
  and real clipboard copy (0.1.3 only showed a toast).
- Sidebar grouped into waiting-for-sync / my forms / answered / open forms;
  identity & network dialog (copy address, counters, resync, key import).
- No emoji glyphs (they rendered as missing-glyph boxes).

- Fix (found in the real Basecamp GUI): the builder's type/required chips
  sit in a nested Repeater, where `index` is the CHIP's index - clicking
  "Single choice" on Q2 appended a phantom question instead. Handlers now use
  the question's captured index.

- Contested-id and link-mismatch warnings (answering disabled).

### Android app (new, `mobile/`)
- WhisperBox for Android with the same flows and look as the desktop view:
  forms list, builder (4 question types, required, options, allow-list),
  answering with validation, receipts, close, CSV via the share sheet, QR
  share + QR scan, `whisperbox://` deep links, identity & network screen.
- Network via the Loam shared node (loam-transport, opt-out → own node).
- Protocol = `packages/client` - a JS mirror of the C++ core built only from
  the shared reference packages (engine, merge, portable crypto, loam-sync
  catch-up). Interop-tested against the real C++ core in both directions.

### Hub
- `whisperbox join` uses `importForm` (pulls immediately); new
  `whisperbox confirm <form> <respondent>`; `list` shows receipts.
- Fix: text questions containing `?` ("Name?") were parsed as choice
  questions with no options; options now follow the LAST `?` and only for
  radio/checkbox. README shows the `--question=-...` form argparse needs.

### Verified 2026-10-01 (Atlas)
- `nix build .#whisperbox_core .#whisperbox` -> portable `linux-amd64`
  packages, manifest 0.3.0, all 16 core methods exposed.
- Real network (logos.test fleet), three headless hubs on the built core:
  create -> join by link -> sealed answer -> decrypt -> receipt -> CSV,
  cold-start catch-up via SYNC_REQ, privacy checks, close.
- Basecamp 0.2.0 AppImage: installed from a package repo through the
  package manager (dependency chain resolves), then both directions against
  a hub over the network - GUI creates/shares (QR decodes, copy works),
  decrypts, sends receipt, exports CSV; GUI opens a link before sync, answers
  all question types, sees the receipt.

### Tests (all runnable without nix: `scripts/test.sh`)
- The JS reference `mergeOne` had the same reversed insert as the C++ port;
  fixed, with an incremental-vs-batch merge test (50 worlds).
- Squatting: TS unit tests, a squat golden reproduced by C++ for 30 arrival
  orders, and an end-to-end scenario (creator unaffected, pinned respondent
  answers the real creator, unpinned respondent refused).
- Portable crypto (`crypto-portable.mjs`, used by the phone) byte-identical to
  the Node reference and the fixtures; JS client <-> C++ core interop test
  over a stdin/stdout bridge.
- C++ engine parity against the TS golden vectors (merge/fold/creator view);
  the golden creator view is now non-empty (it was `{}`, so the projection was
  never pinned).
- End-to-end test of the real `whisperbox_core_impl.cpp` over a fake
  delivery bus (`whisperbox_core/test/fakesdk`): Phase 6 scenarios A
  (create/respond/decrypt/receipt/CSV), B (cold start) and C (privacy), plus
  whitelist, forged-response, legacy-compat, close, restart and log-repair
  checks.
- QML harness works with system Qt6, renders fixtures generated from the real
  core, and asserts the view->core call contract per screen.

## 0.1.3 (2026-08-23)
- **QML v0.3: Form detail views.** Respondent view (questions + text inputs + submit
  wired to core + privacy note) and creator view (stats row, share card with URI,
  responses list with Q&A rows, decrypted/confirmed/encrypted badges).
- **Flickable scrolling** for long forms in the main pane.
- **Share overlay** modal with URI, privacy note, and copy button.
- **CSV export** button (stub — toast "coming soon").
- **Answers state tracking** per question, reset on form switch.
- **`shareUri()`** generates `whisperbox://form?{json}` links.
- **`doSubmit()`** wired to `whisperbox_core.submitResponse`.
- Fixed: removed invalid `border.style: Qt.DashLine` and `border.left/top/bottom`
  (silent QML killers that caused grey fallback).
- Deploy path clarified: `plugins/whisperbox/Main.qml` (not `modules/`).

**Download:** https://github.com/vpavlin/whisperbox-logos/releases/tag/v0.1.3

## 0.1.2 (2026-08-21)
- **Fix: question type selector was corrupting form definitions.** The combo's
  `onActivated` read `modelData`, which resolves to the *Repeater* context, not the
  combo item — so selecting a type persisted the raw index number (`"type": 3`)
  instead of the string. The display always fell back to "text", and affected
  questions rendered NO input widget in the answer view (unanswerable). Now maps
  index → type string explicitly.
- **Fix: legacy forms with unknown/numeric question types are now answerable.**
  Answer view normalizes types (`normType`) and degrades choice questions without
  usable options to a text input, so pre-0.1.2 forms stay usable.


## 0.1.1 (2026-08-21)
- Share/QR: short URI `whisperbox://form?id=<id>` — the full def now arrives via Waku
  sync instead of being embedded in the link; QR drops from version ~5+ to 1-2
  (actually scannable). QR canvas enlarged 132→160px.
- Fix: `importForm` rejected ALL `whisperbox://` URIs (first JSON parse threw before
  URI handling — dead code path); now accepts short + legacy b64 URIs, publicKey
  optional on import (filled from the canonical event).
- View: create-form modal scrolls when it outgrows the window (content was clipped);
  question text field goes multi-line for textarea-type questions; remove-question
  button aligned to row height; "waiting for form data" hint for id-imported forms
  before sync lands.

## Unreleased
- P0: repo scaffold, loam-sync + loam-transport submodules, target Basecamp 0.2.3 confirmed.
