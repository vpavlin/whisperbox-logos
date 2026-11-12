# Feedback demo: ask WhisperBox for feedback from your own Basecamp app

A minimal Basecamp app (`wb_feedback_demo`) with a **Send feedback** button (ADR 0023).

1. In the WhisperBox studio, make the form (for feedback, turn on *Let each person send several
   answers*) and click **Export**. It saves `~/Downloads/whisperbox-form-<id>.json`.
2. Wrap it as a JS file next to your view, so the view can import it from its own folder:
   ```sh
   { echo '.pragma library'; printf 'var file = '; cat whisperbox-form-<id>.json; echo ';'; } > qml/FeedbackForm.js
   ```
3. Declare that your app uses the intent, in its `metadata.json` (Basecamp refuses undeclared
   requests with `not_declared`):
   ```json
   "uses": [{ "intent": "whisperbox.respond", "cardinality": "single" }]
   ```
4. Ask Basecamp for the intent:
   ```qml
   import "FeedbackForm.js" as Form
   logos.request("whisperbox.respond", { form: JSON.stringify(Form.file) }, function (r) {
       // r.ok, r.data.submitted: true when an answer was sent, false when the person left the form
   })
   ```
WhisperBox checks the creator's signature, shows the form, seals the answer so only the creator (and
co-owners) can read it, and sends it over Logos Delivery. If WhisperBox isn't installed, Basecamp
offers to install it. The file holds only the creator-signed form: no keys, nothing that isn't
already public on the network.

Build: `nix build .#lgx-portable` in this folder.
