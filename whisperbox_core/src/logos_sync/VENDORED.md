Vendored from github.com/vpavlin/loam-sync @ fd13c02 (basecamp/logos_sync/): catchup.hpp,
event.hpp, reconcile.hpp — byte-for-byte copies (the same revision third_party/loam-sync pins
and the mobile app's catchup.ts comes from). Do not edit here; change upstream and re-vendor:
  cp third_party/loam-sync/basecamp/logos_sync/{catchup,event,reconcile}.hpp whisperbox_core/src/logos_sync/
Vendored (not included from third_party/) because the nix build's src is whisperbox_core/ only.

WhisperBox uses ONLY the RBSR catch-up (fp/ids/need over event ids). It keeps its own event
merge (min-HLC), signing (whisperbox-sig-v1 + inner response signature) and ECIES sealing —
see whisperbox_engine.hpp / whisperbox_identity.hpp / whisperbox_crypto.hpp.
