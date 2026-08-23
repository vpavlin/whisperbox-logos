# Changelog

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
