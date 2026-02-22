{
	description = "systat - cross-platform system monitoring GUI";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		zig-overlay.url = "github:mitchellh/zig-overlay";
	};

	outputs = { self, nixpkgs, ... }@inputs:
		let
			allSystems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs allSystems;

			buildSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
			forBuildSystems = nixpkgs.lib.genAttrs buildSystems;

			zigTargets = {
				"x86_64-linux" = "x86_64-linux-musl";
				"aarch64-linux" = "aarch64-linux-musl";
				"x86_64-windows" = "x86_64-windows-gnu";
				"aarch64-windows" = "aarch64-windows-gnu";
				"x86_64-darwin" = "x86_64-macos";
				"aarch64-darwin" = "aarch64-macos";
			};

			# Pre-fetched Zig dependencies (fixed-output derivation)
			# Update this hash when build.zig.zon changes:
			#   nix run nixpkgs#nix-prefetch -- '{ ... }'
			# or manually: zig build --fetch=all && nix hash path $ZIG_GLOBAL_CACHE_DIR
			zigDepsHash = "sha256-0aSOc7ObMVVNYEZXc1JYr5n4VJbqBHBaW6pIVj7sGLk=";
		in {
			packages = forBuildSystems (buildSystem:
				let
					pkgs = import nixpkgs {
						system = buildSystem;
						overlays = [ inputs.zig-overlay.overlays.default ];
					};
					zig = pkgs.zigpkgs."0.15.2";
					isDarwin = pkgs.stdenv.isDarwin;

					zigDeps = pkgs.stdenv.mkDerivation {
						pname = "systat-zig-deps";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = [ zig pkgs.git pkgs.cacert ];

						outputHashMode = "recursive";
						outputHashAlgo = "sha256";
						outputHash = zigDepsHash;

						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$out
							export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							zig build --fetch=all
						'';

						dontInstall = true;
						dontFixup = true;
					};

					mkSystat = { targetSystem ? buildSystem, cross ? false }:
						let
							zigTarget = zigTargets.${targetSystem};
							targetIsWindows = builtins.match ".*windows" targetSystem != null;
							binaryName = if targetIsWindows then "systat.exe" else "systat";
						in pkgs.stdenv.mkDerivation {
							pname = "systat-${targetSystem}";
							version = "0.1.0";
							src = ./.;

							nativeBuildInputs = [ zig ]
								++ pkgs.lib.optionals (isDarwin && !cross) [
									pkgs.darwin.cctools
									pkgs.apple-sdk
								];

							buildPhase = ''
								export HOME=$TMPDIR
								export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
								mkdir -p $ZIG_GLOBAL_CACHE_DIR
								cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
								chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
								${pkgs.lib.optionalString isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
								zig build -Doptimize=ReleaseFast --release=fast ${if cross then "-Dtarget=${zigTarget}" else ""}
							'';

							installPhase = ''
								mkdir -p $out/bin
								cp zig-out/bin/${binaryName} $out/bin/
							'';

							dontFixup = true;
						};
				in {
					default = mkSystat { };
				} // (if buildSystem == "x86_64-linux" then {
					linux-x86_64 = mkSystat { targetSystem = "x86_64-linux"; };
					linux-aarch64 = mkSystat { targetSystem = "aarch64-linux"; cross = true; };
					windows-x86_64 = mkSystat { targetSystem = "x86_64-windows"; cross = true; };
					windows-aarch64 = mkSystat { targetSystem = "aarch64-windows"; cross = true; };
					macos-aarch64 = mkSystat { targetSystem = "aarch64-darwin"; cross = true; };
				} else { }));

			checks = forBuildSystems (system:
				let
					pkgs = import nixpkgs {
						inherit system;
						overlays = [ inputs.zig-overlay.overlays.default ];
					};
					zig = pkgs.zigpkgs."0.15.2";
					isDarwin = pkgs.stdenv.isDarwin;

					zigDeps = pkgs.stdenv.mkDerivation {
						pname = "systat-zig-deps";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = [ zig pkgs.git pkgs.cacert ];

						outputHashMode = "recursive";
						outputHashAlgo = "sha256";
						outputHash = zigDepsHash;

						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$out
							export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							zig build --fetch=all
						'';

						dontInstall = true;
						dontFixup = true;
					};
				in {
					build = self.packages.${system}.default;

					test = pkgs.stdenv.mkDerivation {
						pname = "systat-test";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = [ zig ]
							++ pkgs.lib.optionals isDarwin [
								pkgs.darwin.cctools
								pkgs.apple-sdk
							];

						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							mkdir -p $ZIG_GLOBAL_CACHE_DIR
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
							${pkgs.lib.optionalString isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
							timeout 600 zig build test || {
								echo "Tests timed out or failed after 10 minutes"
								exit 1
							}
						'';

						installPhase = ''
							mkdir -p $out
							echo "tests passed" > $out/result
						'';
					};
				});

			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs {
						inherit system;
						overlays = [ inputs.zig-overlay.overlays.default ];
					};
					zig = pkgs.zigpkgs."0.15.2";
				in {
					default = pkgs.mkShell {
						buildInputs = [
							zig
							pkgs.hyperfine
							pkgs.pkg-config
						];
						# DVUI vendors SDL3 and builds it from source using Zig's C compiler.
						# Nix's NIX_CFLAGS_COMPILE interferes with Zig's sysroot detection,
						# causing framework search to fail on macOS.
						shellHook = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
							unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
						'';
					};
				});
		};
}
