# ADR 0003 — Answers are opaque sealed blobs, interpreted only by the creator

Status: accepted (0.1.0; per-form dev tag 0.3.7). Recorded 2026-10-03.

## Context
The original whisperbox sealed the whole answer to the creator. Anything visible on the wire
(respondent, form id, even a signature) links people to forms.

## Decision
- `response.submit` carries only `encryptedPayload`: ECIES (secp256k1 ECDH + HKDF +
  ChaCha20-Poly1305) over the whole answer JSON, sealed to the form's key.
- The event is content-addressed (`resp:<sha256(blob)>`) and MUST NOT carry `pub`/`sig`
  (a public key is an address). Admission rejects any that do.
- The blob doesn't name its form. The fold keeps all blobs in one pool; the creator
  trial-opens each with its form keys (cached) and does every check after decryption, in
  the creator view: which form, closed or expired, signature, whitelist, one per respondent,
  cap, edits.
- Members-only and editable forms add an inner signature inside the sealed payload.
- Since 0.3.7 the event's `dev` / `hlc.dev` is a per-form tag, not the device id (before,
  answers to different forms were linkable by device).

## Consequences
- Relays, hubs and other respondents learn only that some answer exists, and when.
- Every creator check is deterministic over the HLC-ordered pool, so co-owners and the
  creator's other devices compute the same accepted set.
- Creator decryption costs one trial open per (new blob x own form) on first sight.
