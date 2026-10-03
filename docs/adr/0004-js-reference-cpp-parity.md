# ADR 0004 — A JS reference implementation, matched by the C++ core through shared fixtures

Status: accepted (0.1.0; client interop 0.2.0). Recorded 2026-10-03.

## Context
Three implementations must agree byte for byte: the desktop core (C++ Basecamp module), the
phone (React Native / Hermes) and the tests. A protocol drift shows up as "answers never
arrive" with no error.

## Decision
- `packages/contract` (events, crypto, answers) and `packages/engine` (fold, creator view)
  in plain JS are the **reference**. The phone runs the same files through
  `packages/client`.
- `whisperbox_core` mirrors them in C++ (`whisperbox_engine.hpp`, `whisperbox_identity.hpp`).
- Agreement is enforced by fixtures generated from the reference (crypto vectors, golden
  fold/view runs over many arrival orders, validation and scoring cases) and checked by the
  C++ parity tests, plus an interop test that drives the real C++ core from the JS client
  over a bridge. Shared rules (answer validation, scoring) live in one place per language
  and are pinned by the same fixture.
- Workflow: change JS, regenerate fixtures, make C++ match, never hand-edit generated files.

## Consequences
- Every protocol change touches two implementations and a fixture; slower to write,
  but drift is caught before a release (`scripts/test.sh` layers 1-4 and 7).
- Module-layer behaviour that isn't in the engine (drafts, housekeeping, snapshot flags) is
  covered by the E2E test and the interop test instead of fixtures.
