{
  description = "epub reader";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-utils,
    ...
  }: let
    overlays = [
      (final: prev: {
        zigpkgs = inputs.zig-overlay.packages.${prev.system};
      })
    ];

    systems = builtins.attrNames inputs.zig-overlay.packages;
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {inherit overlays system;};
        zig = inputs.zig-overlay.packages.${system}."0.16.0";

      in {
        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.pkg-config
            pkgs.egl-wayland
            pkgs.wayland-scanner
            pkgs.libGL
            pkgs.xorg.libX11
            pkgs.xorg.libXcursor
            pkgs.xorg.libXrandr
            pkgs.xorg.libXinerama
            pkgs.xorg.libXi
            pkgs.xorg.libXfixes
            pkgs.xorg.libXrender
            pkgs.xorg.libXext
            pkgs.xorg.libXau
            pkgs.xorg.libXdmcp
            pkgs.libxkbcommon
          ];

          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [
              pkgs.xorg.libX11
              pkgs.xorg.libXcursor
              pkgs.xorg.libXrandr
              pkgs.xorg.libXinerama
              pkgs.xorg.libXi
              pkgs.xorg.libXfixes
              pkgs.xorg.libXrender
              pkgs.xorg.libXext
              pkgs.libGL
              pkgs.libxkbcommon
              pkgs.libGL
              pkgs.vulkan-loader
              pkgs.wayland
              pkgs.libxkbcommon
              pkgs.libdecor
            ]}:$LD_LIBRARY_PATH"
          '';
        };

        # Build the EPUB reader as a Nix package
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "pubix";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = [
              pkgs.pkg-config
          ];

          buildPhase = ''
            # Build the CLI tool first
            zig build --prefix $out

            # Build the frontend
            cd frontend
            zig build --prefix $out
          '';

          installPhase = ''
            # Binaries are already installed by zig build --prefix
            echo "Installation completed"
          '';
        };

        devShell = self.devShells.${system}.default;
      }
    );
}
