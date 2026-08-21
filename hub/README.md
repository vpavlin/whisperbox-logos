# WhisperBox Hub — headless command-line operation

Run `whisperbox_core` in a **logoscore daemon** and drive it from the shell:
create forms, join, answer, decrypt responses — no Basecamp UI, no click magic.
This is the HUB-PLAN (Option B realized): the same `.lgx` code that Basecamp
talks to, so protocol parity with Basecamp clients is guaranteed by construction.

```
whisperbox up                          # daemon + load whisperbox_core
whisperbox identity new                # keypair in the hub's data dir
whisperbox create --title "Lunch?" \
    --question "radio:Pick?Sushi|Pizza|Tacos" \
    --question "-text:Allergies?"       # leading "-" = optional question
whisperbox list
whisperbox join whisperbox://form?id=form-...
whisperbox answer form-... -q question_1=0
whisperbox responses form-...          # creator only: decrypts the pool
whisperbox uri form-...                # share URI for Basecamp respondents
whisperbox raw confirmResponse form-... 0xabc...   # escape hatch (any method)
```

## Architecture

```
whisperbox (this script, python3)
   └─ logos-hub (generic profile→daemon→call wrapper; github.com/vpavlin/logos-hub)
        └─ logoscore daemon (logos-co/logos-logoscore-cli, PINNED — see below)
             ├─ whisperbox_core 0.1.0  (.lgx from the catalog release)
             └─ delivery_module      (Waku node, pinned logos.test entry nodes —
                                      self-bootstrapped by whisperbox_core)
```

`whisperbox_core` is fully self-driving: it creates the Waku node with the
pinned fleet entry nodes, subscribes `/whisperbox/1/all/proto`, creates the SDS
channel, and runs a hub QTimer (node-start retry, 60s seed re-broadcast,
SYNC_REQ catchup backoff). Nothing to feed it after `up`.

## Setup (on the hub host)

```sh
HUB_HOME=~/whisperbox-hub; mkdir -p $HUB_HOME && cd $HUB_HOME

# 1. logoscore — PINNED to the SDK generation the .lgx was built against.
#    master's protocol codec (canonical {"_bytes": base64url}, 2026-07-28)
#    crashes old-gen modules on byte payloads (std::length_error in an async
#    FFI callback). bb2a224 pins liblogos 64de644ec6 / protocol 664b43f18a —
#    the same revs as builder afe4430 that built whisperbox_core 0.1.0.
git clone https://github.com/logos-co/logos-logoscore-cli
cd logos-logoscore-cli && git checkout bb2a224
nix build .#cli-bundle-dir          # → result/bin/logoscore (portable: matches portable .lgx)

# 2. modules dir — extract the portable .lgx pair (gzip tarballs):
mkdir -p modules dl
curl -sLO https://github.com/jimmy-claw/whisperbox-basecamp/releases/download/catalog-v0.1.0/logos-whisperbox_core-module-lib.lgx
curl -sLO https://github.com/jimmy-claw/whisperbox-basecamp/releases/download/catalog-v0.1.0/logos-delivery_module-module-v0.2.3.lgx
for pair in "logos-whisperbox_core-module-lib:whisperbox_core" \
            "logos-delivery_module-module-v0.2.3:delivery_module"; do
  f=${pair%%:*}; n=${pair##*:}; mkdir -p modules/$n
  gunzip -c dl/$f.lgx | tar x -C modules/$n
  cp modules/$n/variants/linux-amd64/* modules/$n/
  echo linux-amd64 > modules/$n/variant; rm -rf modules/$n/variants
done

# 3. logos-hub + profile:
git clone https://github.com/vpavlin/logos-hub
export PATH=$PATH:$HUB_HOME   # so `whisperbox` finds ./logos-hub (or set WHISPERBOX_HUB)
cp hub/whisperbox $HUB_HOME/  # or add this repo's hub/ to PATH
whisperbox up                  # writes ~/.logos-hub/profiles/whisperbox.json, starts daemon
```

`whisperbox up` renders the profile itself (modulesDir + `WHISPERBOX_CORE_DATA={data}`
+ offscreen Qt), so per-host paths never live in a committed file.

## State & isolation

- Per-profile runtime state: `~/.logos-hub/run/whisperbox/{cfg,data,daemon.log}`
  (logoscore config dir + module data).
- whisperbox_core identity + event log persist in the profile's data dir
  (`WHISPERBOX_CORE_DATA`), surviving daemon restarts.
- One hub = one identity. Run more hubs (e.g. A/B testing) with
  `WHISPERBOX_PROFILE=whisperbox-b WHISPERBOX_HUB_HOME=~/whisperbox-hub-b`.

## Known sharp edges

- **logoscore pin is load-bearing.** If you re-pin the .lgx to a newer SDK
  generation, re-derive the matching logoscore-cli commit (compare flake.lock
  revs for logos-liblogos / logos-protocol / logos-cpp-sdk against the builder
  pin used for the build).
- The old nix `logos-logoscore-cli-0.1.0` store package (what P3 used) does NOT
  route delivery→module events across host processes (P3.7 platform gap —
  see cerebrum docs/infrastructure/logoscore-cli-event-gap.md). The pinned
  source build above is the fix; verify with `whisperbox status` counters
  (rxRaw must move when peers broadcast) before trusting a hub.
