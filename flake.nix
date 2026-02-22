{
  description = "systat - cross-platform system monitoring GUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
        zig = pkgs.zigpkgs."0.15.2";
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig
            pkgs.hyperfine
            pkgs.sdl3
            pkgs.pkg-config
          ];
        };
      }
    );
}
