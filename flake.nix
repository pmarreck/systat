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
            pkgs.pkg-config
          ];
          # DVUI vendors SDL3 and builds it from source using Zig's C compiler.
          # Nix's NIX_CFLAGS_COMPILE interferes with Zig's sysroot detection,
          # causing framework search to fail. We unset the problematic vars
          # so Zig can find macOS frameworks via its native sysroot logic.
          shellHook = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
            unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
          '';
        };
      }
    );
}
