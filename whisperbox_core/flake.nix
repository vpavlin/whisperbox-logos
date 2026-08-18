# whisperbox_core dev flake — P2 parity test (TS↔C++ crypto byte-parity).
# Build:   nix build whisperbox_core            (from repo root)
# Run:     result/bin/parity-test <repo-root>
# (The module build itself comes in P3 via logos-module-builder; this flake only
#  compiles the header-only core against nixpkgs OpenSSL + nlohmann_json. Fixtures
#  are read from the live repo tree at runtime — no store bundling.)
{
  description = "whisperbox_core dev tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    parityTest = pkgs.stdenv.mkDerivation {
      pname = "whisperbox-parity";
      version = "0.1.0";
      src = ./.; # whisperbox_core/ only (headers + test)
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
