# ADR 0014 — Local-only state and a data folder that can't silently move

Status: accepted (0.3.0-0.3.4). Recorded 2026-10-03.

## Context
A Basecamp install minted a new identity on every start: the module host's working directory
(an AppImage mount) changed each launch and the core wrote to a relative path. Losing the
identity loses every answer sealed to it.

## Decision
- Data folder: `$WHISPERBOX_CORE_DATA`, else the first writable of `~/.whisperbox-core` (home
  from the user database, never relative) and the host's instance folder; prove writability;
  adopt files from another candidate that already has an identity; show the folder and any
  problem in the Identity panel. Writes are atomic; unreadable files are quarantined.
- Purely local (never on the wire): drafts and scheduled drafts, unsent answer drafts, my
  answers' plaintext copies, seen counters, hidden forms, automatic-receipt switches, pinned
  creators.

## Consequences
- Drafts and "new answers" badges don't sync between a user's devices. Accepted for now.
- The phone keeps the same state in SecureStore / app storage.
