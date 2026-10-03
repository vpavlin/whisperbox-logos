# ADR 0012 — Co-owners receive the form key, sealed to them

Status: accepted (0.3.7 desktop / 0.3.8 Android). Recorded 2026-10-03.

## Context
Teams run surveys together; sharing the creator's identity would hand over every form and the
signing key.

## Decision
- `form.coowner {owner, sealedKey}`: the creator seals that one form's private key to the
  co-owner's identity public key (their "co-owner code", shown under Identity). Possible
  only where the form key is on the device (not for Keycard forms created elsewhere).
- Co-owners decrypt answers, export CSV, send receipts and replies (also automatic
  receipts). Closing, re-opening, editing and adding co-owners stay with the creator; the
  fold enforces this.
- No revocation: a key once shared can't be taken back. The UI says so before adding.

## Consequences
- The co-owner list (addresses) is public in the log.
- Revocation would need a key rotation (new form key + re-publish); deferred.
