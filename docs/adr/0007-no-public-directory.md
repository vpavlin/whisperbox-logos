# ADR 0007 — No public form directory; local hide and delete

Status: accepted (0.3.0). Recorded 2026-10-03.

## Context
Early builds listed every form on the topic. Anyone can publish a form, so the list was a
spam and phishing channel, and a feed of all forms leaks what everybody is asking.

## Decision
- The app lists only forms you created, answered, or opened from a link (or are waiting
  for after opening a link). Everything else in the log stays invisible.
- "Hide" moves a form to a Hidden section; "delete" removes it from this device's lists.
  Both are local; the events stay in the shared log.

## Consequences
- Distribution is by link or QR code only.
- The log still contains every form (it is one topic); this is a UI decision, not a privacy
  boundary. Form definitions are public by design.
