# ADR 0001 — Per-form sealing keys (soft-derived now, Keycard-exported next)

Status: accepted (2026-10-01). Steps 1–2 implemented; 3–4 planned.

## Context

Until 0.2.0 every form's `publicKey` was the creator's **identity** key. One key both
signed all of a creator's events and opened every answer they ever received. That made
two things impossible:

- **Always-on validation.** Blind hubs re-serve sealed answers but cannot tell a valid
  answer from well-formed garbage, so junk can't be filtered. A hub that could open
  answers would need the identity key, which is unacceptable on an always-on box.
- **Hardware custody.** Keycard keeps keys on the card and can sign there, but it
  cannot do ECDH, so it cannot open answers with an on-card key.

## Decision

Each form is sealed to its **own** key. Respondents are unchanged (they always sealed
to `form.publicKey`), so 0.2.x respondents interoperate with no wire change.

**Soft derivation** (identity key on the device; desktop, hub, phone without a card):

    formPriv = first valid scalar of
               HKDF-SHA256(ikm = identityPriv, salt = "whisperbox-formkey-v1",
                           info = utf8(lower(formId)) [ || "#" || i  for retry i >= 1 ], L = 32)

Deterministic: every form key is re-derived from the identity, nothing new to back up.

**Keycard** (step 3): the form key is exported from the EIP-1581 subtree, the only
subtree Keycard allows to leave the card:

    m/43'/60'/1581'/22338'/formKeyIndex(formId)'
    formKeyIndex = u32be(sha256("whisperbox-formkey-v1|" || lower(formId))[0..4]) & 0x7fffffff

One tap per form at creation. The root and signing keys never leave the card;
losing the phone loses nothing (tap again on a new device). Form events stay signed by
the identity (on-card, or via the delegation-cert scheme from scala/logos-sync).

**Opening.** A sealed blob deliberately does not say which form it answers (that would
publish per-form answer counts), so the creator trial-opens each blob against the keys
of their own forms (results cached per blob; a miss is retried only when the key set
grows). The key that opens a blob must be the sealing key of the form the plaintext
claims; otherwise the blob is ignored. Legacy forms (`publicKey == identity pub`) keep
opening with the identity key.

Shared golden vectors: `packages/contract/test/fixtures/crypto-formkeys.json` (JS
reference + portable + C++ parity), E2E section "per-form keys".

## Next

3. **Keycard on mobile**: reuse scala's `loam-keycard`, add `exportKey(path)`; store the
   exported form keys in SecureStore, re-exportable from the card.
4. **Validator hub** (the hub *is* `whisperbox_core` headless, plus wrapping): a form
   may name a validator pubkey in its signed definition; the creator hands that hub the
   form's key (`importFormKey`, never the identity). The validator opens answers, checks
   them against the questions / inner signature / whitelist, and re-serves + acknowledges
   only valid ones. Respondents' apps show "readable by the creator and validator 0x…".
   Hub guardrail flag: refuse `importIdentity`. Compromise of the hub leaks that one
   form's answers only.

## Consequences

- A leaked form key exposes one form; the identity and other forms stay safe.
- Creator decryption costs one ECDH per (new blob × own form) on first sight, then is
  cached. Fine for desktop/hub; on Hermes it is bounded by the cache.
- A 0.2.0-or-older creator app cannot open answers to forms created by the new
  version on another device of the same identity unless it is updated (it only knows
  the identity key). Respondents of any version are unaffected.
