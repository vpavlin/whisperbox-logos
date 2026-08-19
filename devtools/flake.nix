# devtools — developer-only builds that are NOT part of the module.
# Currently: the TS↔C++ crypto parity test (P2 gate). Build from repo root:
#   nix build ./devtools            → result/bin/parity-test <repo-root>
{
  description = "whisperbox-logos dev tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    parityTest = pkgs.stdenv.mkDerivation {
      pname = "whisperbox-parity";
      version = "0.1.0";
      src = ../whisperbox_core; # headers + test (compile-only; fixtures read at runtime)
      buildInputs = [ pkgs.openssl.dev pkgs.nlohmann_json ];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        $CXX -std=c++17 -O1 \
          -I . \
          -I ${pkgs.nlohmann_json}/include \
          test/parity_test.cpp \
          -o parity-test -lssl -lcrypto
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp parity-test $out/bin/
      '';
    };
  in {
    packages.x86_64-linux = { inherit parityTest; parity-test = parityTest; default = parityTest; };
  };
}
