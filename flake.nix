{
  description = "WhisperBox Basecamp module pair: whisperbox_core (C++ engine + ECIES + delivery sync) and whisperbox (pure-QML view).";

  inputs = {
    # Each module keeps its OWN pins (builder 0.3.1 = 16e2f6 in whisperbox_core/ and module/). The root
    # flake used to force an older builder onto both with `follows`, and the 0.5.3 linux-amd64 core
    # built here did not match a build of whisperbox_core/ (open-review 2026-11-02, FR-1). Only the
    # view's path:../whisperbox_core is redirected, so both share one core derivation.
    whisperbox_core.url = "path:./whisperbox_core";
    view.url = "path:./module";
    view.inputs.whisperbox_core.follows = "whisperbox_core";
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
