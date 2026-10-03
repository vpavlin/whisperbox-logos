# ADR 0015 — Join the device's existing delivery node

Status: accepted (0.3.4). Recorded 2026-10-03.

## Context
Basecamp runs one `delivery_module` for all apps; Android runs one node per device in the
Loam app. When another app had already created the node, WhisperBox reported "Context already
initialized" and retried forever, never connecting.

## Decision
- Desktop: if `createNode` fails with "already initialized", treat the node as up and join
  it (subscribe, catch up). Never create or start it a second time.
- Android: prefer the Loam shared node (bound before anything touches the transport); fall
  back to an embedded node when Loam isn't installed or approved, switchable in settings.
- Node config pins the logos.test fleet entry nodes (a bare preset gives zero bootstrap peers).

## Consequences
- Another app's node settings (e.g. edge mode) apply to WhisperBox too.
- The fake delivery bus in the E2E test models "already initialized".
