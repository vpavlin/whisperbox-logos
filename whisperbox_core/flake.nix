{
  description = "WhisperBox privacy-first forms CORE module (event log + ECIES sealing + delivery sync); headless AND the desktop ui backend.";

  inputs = {
    # Same pinned SDK rev + channel-capable delivery_module as qaku-logos, so both
    # modules build against ONE SDK (avoids cross-module IPC skew). Re-pin to the
    # rev your installed Basecamp was built on.
    delivery_module.url = "github:logos-co/logos-delivery-module/0fb3a7427b29c98ab0fa2465bcd1e90cbfdf50a3";
    logos-module-builder.url = "github:logos-co/logos-module-builder/afe4430ee6eb7ba45c08a516a43e18500720c715";
    delivery_module.inputs.logos-module-builder.follows = "logos-module-builder";
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
