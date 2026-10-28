# ADR 0019 — LNS names in members-only lists, resolved to addresses at publish

Status: proposed (desktop view). Recorded 2026-10-28.

## Context
A members-only form lists respondent addresses (`whitelist.type = "addresses"`). The
creator has to collect a `0x` address from every person first, out of band. LNS names
(looked up through the optional `names` Basecamp module) give people a
name others can look up, with text entries the holder sets.

## Decision
- A person links once: their name's `whisperbox.address` text entry holds their
  WhisperBox address. Only the name's holder can set it, so the entry is the proof. The
  Identity screen shows the `names set-text` command with this device's address.
- In the builder's allow-list an entry starting with `0x` is an address, as before; any
  other entry is an LNS name (`alice`; a trailing `.lez` is ignored).
- The creator's view resolves the names through `names.resolve` when publishing, saving an
  edit or scheduling, and puts only the addresses into the form. A name that is not
  registered, has no valid linked address, or can't be looked up (no `names` module) stops
  the publish with a message naming it; it is never dropped.
- `names` is an optional dependency of the view. The core, the wire format, the hub, the
  Android app and the SDK are unchanged.

## Consequences
- Every client and co-owner checks answers against plain addresses, so the accepted set is
  still deterministic (ADR 0003). A name whose entry changes later doesn't change a
  published form; the creator re-saves it to pick up the new address. A scheduled form uses
  the addresses resolved when it was scheduled.
- Names are kept only in the local draft's builder state. Editing a published form shows
  its addresses, not the names.
- Whitelists are public. Anyone who knows or guesses a name can look up its address and
  see whether that person is on a form's list. LNS names are private unless known or
  guessed; this is the same limit.
- Not combinable with anonymous forms, like any members-only list (ADR 0011).
