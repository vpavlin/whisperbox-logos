{
  description = "WhisperBox Respond: answer one form, opened from a link or the whisperbox.respond intent (ADR 0021). Basecamp 0.3";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/3a64943fe6827bab4c4686fb35c37d24d5df0710";   # tag 0.3.3 (pairs with Basecamp 0.3.2), pinned to its commit
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
