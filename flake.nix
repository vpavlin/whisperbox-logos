{
  description = "WhisperBox Basecamp module pair: whisperbox_core (C++ engine + ECIES + delivery sync) and whisperbox (pure-QML view).";

  inputs = {
    # One pinned SDK rev for everything (view, core, delivery build against ONE
    # builder — avoids cross-module IPC skew). Re-pin to the rev your installed
    # Basecamp was built on.
    delivery_module.url = "github:logos-co/logos-delivery-module/0fb3a7427b29c98ab0fa2465bcd1e90cbfdf50a3";
    logos-module-builder.url = "github:logos-co/logos-module-builder/afe4430ee6eb7ba45c08a516a43e18500720c715";
    delivery_module.inputs.logos-module-builder.follows = "logos-module-builder";

    # The core module (headless + desktop backend).
    whisperbox_core.url = "path:./whisperbox_core";
    whisperbox_core.inputs.logos-module-builder.follows = "logos-module-builder";
    whisperbox_core.inputs.delivery_module.follows = "delivery_module";

    # The view module. Its own flake declares `path:../whisperbox_core`, which
    # only resolves when the whole repo is the fetch source; from a root build we
    # override it with follows so the same core derivation is shared.
    view.url = "path:./module";
    view.inputs.whisperbox_core.follows = "whisperbox_core";
    view.inputs.logos-module-builder.follows = "logos-module-builder";
    view.inputs.delivery_module.follows = "delivery_module";
  };

  outputs = inputs@{ ... }: let
    coreOuts = inputs.whisperbox_core.outputs.packages.x86_64-linux;
    viewOuts = inputs.view.outputs.packages.x86_64-linux;
  in {
    packages.x86_64-linux = {
      # Shippable packages (portable linux-amd64 variant).
      whisperbox_core = coreOuts."lgx-portable";
      whisperbox = viewOuts."lgx-portable";
      # Dev variants for lgpm local installs.
      whisperbox_core_dev = coreOuts.lgx;
      whisperbox_dev = viewOuts.lgx;
    };
  };
}
