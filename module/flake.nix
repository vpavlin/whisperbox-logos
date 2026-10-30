{
  description = "WhisperBox Logos Basecamp ui_qml module (pure QML view over the whisperbox_core event-log + ECIES engine), Basecamp 0.3";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/16e2f6bd3c06a5119f8c34448933de183205646c";   # tag 0.3.1, pinned to its commit
    # The WhisperBox engine/sync CORE module - this ui module is a thin view over it.
    whisperbox_core.url = "path:../whisperbox_core";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
