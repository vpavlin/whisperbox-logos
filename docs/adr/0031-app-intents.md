# ADR 0031: App intents in the studio (for Basecamp Voice and other apps)

Status: accepted, 2026-11-24 (studio view 1.1.7; the core is unchanged at 1.1.6). Asked for by Václav, so that
Basecamp Voice can drive WhisperBox: "create a new form based on a template, get a summary of replies".

## Decision

The studio view (`whisperbox`) provides seven intents (`metadata.json` → `provides`, each with a `description`
and, where it changes nothing, `readOnly: true`, which Basecamp Voice reads):

| Intent | Params | Answer |
|---|---|---|
| `whisperbox.forms.list` | — | `{forms: [{id, title, status, responses, newResponses, createdAt, role}], drafts: [{draftId, title}]}`: my own and co-owned forms |
| `whisperbox.forms.create` | `template?` (rsvp, feedback, poll, signup, nps), `title?`, `description?`, `questions?` [{type, text, options?, required?}], `publish?` | By default a **draft**, opened in the studio for the user to check and publish: `{draftId, title, status: "draft"}`. With `publish: true`: published at once, `{formId, title, status: "open", link}` |
| `whisperbox.forms.summary` | `form`, `includeText?` | `{title, status, responses, questions: [{question, type, answered, results?: [{label, count, percent}], stat?, written, answers?}], textIncluded}` |
| `whisperbox.forms.share` | `form` | `{formId, title, link}` |
| `whisperbox.forms.close` / `.reopen` | `form` | `{formId, title, status}` |
| `whisperbox.forms.open` | `form` | Shows it in the studio (handoff) |

- `form` is an id, an exact title or a unique part of a title. It matches only your own and co-owned forms
  (`open` also matches forms you answered or opened).
- Several matches give `bad_request` with the candidates in `data.message`, so the asking app can ask which.
- Question types accept friendly names: choice → radioButtons, multi → checkbox, yesno → boolean, long →
  textarea, rating → scale. Unknown types become text.

## Respondents first (ADR 0029)

- **A summary carries counts, percentages and averages,** plus how many written answers each question has.
- **The written answers themselves** (text questions and "Other" entries, up to 200 per question, 500
  characters each) leave WhisperBox only if two things are both true:
  - the app asks with `includeText: true`;
  - the user then presses **Share written answers** in WhisperBox's own card. The card says the app may send
    them to an AI model that might not run on this computer.

  **Only counts** answers without them.
- **Never** shared: who answered, their addresses, or when.
- **Basecamp confirms every request** with the user. The text card is a second, specific consent, because
  Basecamp's dialog can't say what leaves.

## Not done (yet)

- **Edits to a published form** are not exposed: they need the builder, where the user can see them.
- **No reply to a respondent** and **no CSV export** over intents.
- **Basecamp Voice** must list these intent names in its own `uses` (Basecamp requires the names). That is a
  Basecamp Voice release.

## Tests

`scripts/qml-harness/scenarios.sh` has 10 intent scenarios against the real-core fixtures. The harness can
send an intent (`WB_INTENT`) and answer the card (`WB_LATE_INVOKE`). They check:
- list;
- summary, with no text by default, text when the user shares, counts only when the user declines, and never
  respondent ids;
- an unknown form;
- create as a draft, create and publish with mapped types, an unknown template;
- share; close.

Not yet run in a real Basecamp with Basecamp Voice.
