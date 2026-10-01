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
- **`hub/`** - headless CLI/runner over logoscore (`hub/README.md`).

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
Add the package repository in Basecamp and install **WhisperBox** (it pulls
`whisperbox_core` and `delivery_module`):
`https://raw.githubusercontent.com/jimmy-claw/whisperbox-basecamp/main/logos-repo.json`

Always update `whisperbox` and `whisperbox_core` together (same version).

## Privacy model
- Form definitions (title, questions, who may answer) are public on the topic.
- A response is ECIES-sealed to the form creator's key; on the wire and in the
  fleet store it is an opaque blob with no respondent identity.
- The creator's receipt carries a random id the respondent sealed inside its
  response, so a receipt can't be linked to an address.
- "Only listed addresses" forms: respondents sign inside the sealed payload;
  the creator drops unsigned or unlisted responses.
- Delta vs. the original whisperbox: Logos delivery keeps channel history in the
  fleet store (that's how late joiners catch up). Sealed bytes are useless without
  the form key; form metadata was public by design.

## Development
`scripts/test.sh` runs every layer that doesn't need nix: TS engine
(convergence + golden vectors), C++ crypto + engine parity, an end-to-end test of
the real core module over a fake delivery bus, and the QML render harness +
interaction scenarios. Packages are built with nix on the build host:
`nix build .#whisperbox_core .#whisperbox` (portable `.lgx`).

## License
Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
