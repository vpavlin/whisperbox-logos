{
  description = "WhisperBox privacy-first forms CORE module (event log + ECIES sealing, synced over loam_core); headless AND the desktop ui backend (Basecamp 0.3).";

  inputs = {
    # Basecamp 0.3 stack: builder 0.3.1 and loam_core (upstream delivery_module 0.3.x underneath),
    # the same pins as the other Loam apps (scala, swamp) so one transport serves them all.
    logos-module-builder.url = "github:logos-co/logos-module-builder/3a64943fe6827bab4c4686fb35c37d24d5df0710";   # tag 0.3.3 (pairs with Basecamp 0.3.2), pinned to its commit
    # ADR 0021: delivery_module required (the direct path, Loam's vendored wire header); loam_core
    # optional - used when installed, through the same 7 calls as before (pin unchanged).
    delivery_module.url = "github:logos-co/logos-delivery-module/v0.3.0";
    loam_core.url = "github:vpavlin/loam-basecamp/5db9069d7b953b5876210576393b1dc9ffc19fdf?dir=core";
  };

  # mkLogosModule (not mkLogosQmlModule): a headless core module — no QML view,
  # the plugin glue is generated from src/whisperbox_core_impl.h (universal authoring).
  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
