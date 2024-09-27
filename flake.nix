{
  description = "a high performance communicaton abstraction library";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
    zls.url = "github:zigtools/zls/0.13.0";
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, ... }:
    let
      overlays = [
        (final: prev: rec {
          zigpkgs = inputs.zig.packages.${prev.system};
          zig = zigpkgs."0.13.0";
          zls = inputs.zls.packages.${prev.system}.zls.overrideAttrs
            (old: { nativeBuildInputs = [ zig ]; });
        })
      ];

      systems = builtins.attrNames inputs.zig.packages;
    in flake-utils.lib.eachSystem systems (system:
      let pkgs = import nixpkgs { inherit overlays system; };
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zig
            zls
            # SSL Testing
            openssl
            # Debugging
            gdb
            valgrind
            # Benchmarking
            linuxPackages.perf
            wrk
          ];
        };
      });
}
