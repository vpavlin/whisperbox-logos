# 0023 - Form files, and other Basecamp apps asking WhisperBox for feedback

Status: accepted, 2026-11-12

## Context

Václav wants a form an app can carry: export it, ship it inside a Basecamp app (a feedback button),
or distribute it some other way than looking it up on Logos Delivery. Basecamp apps are the main
target: Basecamp already lets one module ask another for something by intent, and offers to install
a provider when none is installed.

## Decision

1. **Form file.** `exportForm(formId)` (studio: Export) writes `whisperbox-form-<id>.json`:
   ```
   {"whisperbox":"form","v":1,"formId","creator","title","link","events":[form.publish, form.update...]}
   ```
   Only the creator's signed events: the definition is public anyway and the file holds no keys. It
   is saved to ~/Downloads and returned as text.
2. **Opening a file.** `importFormFile(text)`: the first event must be a `form.publish` whose
   signature verifies; every other event must be a signed `form.update` of that form by that creator,
   or the whole file is refused. The creator is pinned (as a link's `by` does; a different pin is
   refused) and every event then goes through the same admission path as an event from the network
   (shape, budget, signature, log caps). Opening the same file again is harmless.
3. **The intent.** `whisperbox.respond` takes `link` or `form` (the file's text). The respond module
   answers the requesting app when the person sends an answer (`{ok:true, data:{formId, submitted:true}}`)
   or leaves without sending (`submitted:false`); a file or link it can't open is `ok:false` with the
   reason. A new request answers a pending one with `submitted:false`.
   ```qml
   logos.request("whisperbox.respond", { form: fileText }, function (r) { ... r.data.submitted ... })
   ```
   A view reads files only from its own folder: ship the export as `FeedbackForm.js`
   (`var file = <the JSON>`) and pass `JSON.stringify(file)`. Example: `examples/feedback-demo`.
4. **Answers still travel over Logos Delivery**, sent by WhisperBox. A file means the form needn't
   be found on the network first (it also opens offline; the answer goes out when the node is up).

## Not now

Answers as files (outside Basecamp, no Logos node) and a JS embed kit for non-Basecamp apps: the same
file format would carry them; build when someone needs them.
