{
  description = "WhisperBox privacy-first forms CORE module (event log + ECIES sealing, synced over loam_core); headless AND the desktop ui backend (Basecamp 0.3).";

  inputs = {
    # Basecamp 0.3 stack: builder 0.3.1 and loam_core (upstream delivery_module 0.3.x underneath),
    # the same pins as the other Loam apps (scala, swamp) so one transport serves them all.
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.1";
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
