# whisperbox-logos

**WhisperBox rebuilt as a local-first, end-to-end-encrypted Logos Basecamp app.**
Privacy-first forms and surveys: the researcher publishes a form, respondents submit
answers that are **E2E-encrypted to the form key** (only the creator and co-owners can decrypt),
and everything syncs peer-to-peer over **Logos Messaging** (one shared topic, plain relay, with
WhisperBox's own set-reconciliation catch-up) - no server, no central storage of readable data.

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
- **`hub/`** - headless CLI over logoscore, for the Basecamp 0.2 runtime (`hub/README.md`).
  For 0.4.x run the core under `logosctl` (Basecamp 0.3 runtime): see [docs/BUILD.md](docs/BUILD.md#headless).
- **`mobile/`** - the Android app (Expo/React Native). Network via the Loam
  shared node (`loam-transport` submodule); protocol via `packages/client`.
- **`packages/client/`** - the WhisperBox protocol in JS (the phone's core), a
  behavioural mirror of `whisperbox_core`, interop-tested against it.
- **`site/`** - the product website (single page, live in-browser sealing demo). Edit
  `site/whisperbox.html`, run `scripts/build-site.sh`, serve `site/` with GitHub Pages.

## Protocol (one shared topic, `/whisperbox/1/all/proto`)
| event | who | notes |
|---|---|---|
| `form.publish` | creator | public form definition, signed; sealing key = the form's own key |
| `response.submit` | respondent | the WHOLE answer ECIES-sealed to the form key; no address on the wire, a random tag per answer |
| `response.confirm` | creator / co-owner | receipt: echoes a random id the respondent sealed (single or batch) |
| `form.close` / `form.reopen` | creator | closed periods are remembered; answers sealed while closed never count |
| `form.update` | creator | edit a published form (latest wins, question ids stable) |
| `form.coowner` | creator | the form key sealed to a co-owner |
| `response.reply` | creator / co-owner | private reply or quiz score, sealed to the answer's reply key |

Append-only event log, union-by-(id, signer) merge, HLC order, RBSR catch-up.
Full protocol: [docs/SPEC.md](docs/SPEC.md).

## Docs
- [docs/SPEC.md](docs/SPEC.md): protocol and application specification
- [docs/BUILD.md](docs/BUILD.md): toolchain, tests, building the `.lgx` and APK, releasing
- [docs/adr/](docs/adr/README.md): architecture decisions (0001-0018)

## Install (Basecamp 0.3)
In Basecamp 0.3, add the repository `https://apps.vpavlin.xyz/logos-repo.json` and install
**WhisperBox**. It pulls `whisperbox_core` and its transport (`loam_core`, which brings the
official `delivery_module`).

| Package | Platforms |
|---|---|
| `whisperbox_core` | Linux x64, Linux ARM64, macOS (Apple Silicon) |
| `whisperbox` (the view) | Linux x64, Linux ARM64, macOS (Apple Silicon) from 0.4.2 |

Always update `whisperbox` and `whisperbox_core` together (same version line). WhisperBox 0.3.x,
the version for Basecamp 0.2.x, is no longer maintained.

## Android
Install **Loam** (the device-wide Logos node) and **WhisperBox** from the F-Droid repository
`https://apps.vpavlin.xyz/fdroid/repo` ("Logos Apps"), open Loam once and approve WhisperBox when asked. Without
Loam, WhisperBox runs its own node (Settings → Identity & network).
Build: see [docs/BUILD.md](docs/BUILD.md#5-android-apk) (arm64 only; release signing reads
`WB_*` from `~/.gradle/gradle.properties` on the build host).

## Privacy model
- Form definitions (title, questions, who may answer) are public on the topic.
- A response is ECIES-sealed to the form creator's key; on the wire and in the
  fleet store it is an opaque blob with no respondent address; its tag is random per answer (0.4.3:
  it used to be derived from the device id, which linked a device's answers - see below).
- The creator's receipt carries a random id the respondent sealed inside its
  response, so other people can't link a receipt to an address (the form's owners can: they hold
  the answer).
- Share links name the creator; a client never seals answers to a form whose
  creator differs from the link, or to a form id two people published.
- Every answer is signed inside the sealed payload by the respondent it names (0.5.0). "Only
  listed addresses" and editable forms drop unsigned answers; on forms open to anyone an unsigned
  answer (an older client, or someone claiming another address) is shown as **unverified**: it
  doesn't count towards the answer limit, take a respondent's place, edit anything or get an
  automatic receipt, and the CSV export marks it `verified=no`.
- Delta vs. the original whisperbox: the network's store nodes keep the sealed messages
  (that's how late joiners catch up). Sealed bytes are useless without the form key; form
  metadata was public by design.
- **Limits today:**
  - On forms open to anyone, a person can still answer once per identity they make (identities
    are free; only a members list stops that).
  - Close dates, the cap and the edit window go by the Logos Delivery timestamp of an answer
    (0.5.0). Until the network turns RLN on, that timestamp is only as honest as the sender's
    node. An answer that arrives without one (over BLE) is judged by its own clock and shown as
    "time not verified".
  - Co-owner access can't be revoked, and there's no forward secrecy. Answer length and timing
    are visible.
- **What sealing does not hide:** the network nodes that relay a response see which node sent
  it and when (there's no mixnet in this path). The creator can't tell who answered an
  anonymous form, but a well-placed network observer could still link a response to a
  sender's network address.
- **On your computer:** the identity key, the forms and your own answers are kept unencrypted
  in the data folder (`~/.whisperbox-core`), readable only by your user (0600 from 0.4.3).
  Anyone with access to your account can read them.

## Development
`scripts/test.sh` runs every layer that doesn't need nix: TS engine
(convergence + golden vectors), C++ crypto + engine parity, an end-to-end test of
the real core module over a fake delivery bus, and the QML render harness +
interaction scenarios, JS-client-vs-C++ interop and the Keycard simulator. Packages are
built with nix (`nix build .#whisperbox_core .#whisperbox`); releases go through
`scripts/release/` (see [docs/BUILD.md](docs/BUILD.md)).

## License
Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
