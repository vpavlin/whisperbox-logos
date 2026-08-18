# whisperbox-logos

**WhisperBox rebuilt as a local-first, end-to-end-encrypted Logos Basecamp app.**
Privacy-first forms and surveys: the researcher publishes a form, respondents submit
answers that are **E2E-encrypted to the form key** (only the creator can decrypt),
and everything syncs peer-to-peer over **SDS Reliable Channels** - no server, no
central storage of readable data.

Rebuild of [whisperbox-org/whisperbox](https://github.com/whisperbox-org/whisperbox)
(forms over Waku) for the Logos stack, built with the
[logos-skills](https://github.com/vpavlin/logos-skills) multiwriter playbook on top of
the shared [loam-sync](https://github.com/vpavlin/loam-sync) (event log + HLC + RBSR
catchup) and [loam-transport](https://github.com/vpavlin/loam-transport) (delivery
module wrapper) libraries. Template: [qaku-logos](https://github.com/vpavlin/qaku-logos).

## Layout
- **`packages/engine/`** - the portable TS spine: fold + invariants + convergence test.
- **`whisperbox_core/`** - the universal C++ core module (engine mirror, ECIES crypto,
  identity, delivery wiring, persistence). Runs behind the view AND headless as a hub.
- **`module/`** - the desktop `ui_qml` view (pure QML over the Logos design system).
- **`hub/`** - headless always-on runner (post-v1).

## Protocol (one shared topic, `/whisperbox/1/all/proto`)
| event | who | notes |
|---|---|---|
| `form.publish` | researcher | public form def + creator signature; deterministic id |
| `response.submit` | respondent | WHOLE response ECIES-sealed to the form key |
| `response.confirm` | researcher | plaintext receipt echo (confirmationId) |
| `form.close` / `form.results` | researcher | sticky close / optional aggregates |

Append-only event log, union-by-id merge, HLC ordering, RBSR cold-start catchup.
One response per (form, respondent) falls out of deterministic event ids.

## Install (Basecamp 0.2.x)
_(pending first release - see CHANGELOG.md)_

## License
Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
