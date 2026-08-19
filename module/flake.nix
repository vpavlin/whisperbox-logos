{
  description = "WhisperBox Logos Basecamp ui_qml module (pure QML view over the whisperbox_core event-log + ECIES engine)";

  inputs = {
    # Same pinned SDK rev + delivery_module the core builds against, so the view,
    # core, and delivery all build against ONE SDK (avoids cross-module IPC skew).
    delivery_module.url = "github:logos-co/logos-delivery-module/0fb3a7427b29c98ab0fa2465bcd1e90cbfdf50a3";
    logos-module-builder.url = "github:logos-co/logos-module-builder/afe4430ee6eb7ba45c08a516a43e18500720c715";
    delivery_module.inputs.logos-module-builder.follows = "logos-module-builder";
    # The WhisperBox engine/sync CORE module - this ui module is a thin view over it.
    whisperbox_core.url = "path:../whisperbox_core";
    whisperbox_core.inputs.logos-module-builder.follows = "logos-module-builder";
    whisperbox_core.inputs.delivery_module.follows = "delivery_module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
