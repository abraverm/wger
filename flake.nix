{
  description = "Dev shell or something for wger (Django + Node + uv)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # uv2nix + friends to build from uv.lock
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    uv2nix,
    pyproject-nix,
    pyproject-build-systems,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        lib = pkgs.lib;

        # Load uv workspace and generate overlay from uv.lock
        workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};
        overlay = workspace.mkPyprojectOverlay {
          # Prefer binary wheels when available for smoother builds
          sourcePreference = "wheel";
        };

        # Place for build fixups if needed (e.g. extra libraries for packages)
        pyprojectOverrides = final: prev: {
          # Replace problematic psycopg packages with system ones
          psycopg = pkgs.python312Packages.psycopg;
          psycopg-c = pkgs.python312Packages.psycopg-c;
        };

        # Python toolchain and package set constructed via pyproject.nix builders
        python = pkgs.python312;
        pythonSet = (pkgs.callPackage pyproject-nix.build.packages {inherit python;}).overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            overlay
            pyprojectOverrides
          ]
        );

        # Production virtualenv built from uv.lock default dependency set
        wgerEnv = pythonSet.mkVirtualEnv "wger-env" workspace.deps.default;
      in {
        formatter = pkgs.nixfmt-rfc-style;

        # Expose buildable package and runnable app
        packages.default = wgerEnv;
        apps.default = {
          type = "app";
          program = "${wgerEnv}/bin/wger";
        };

        devShells.default = pkgs.mkShell {
          # System packages needed for building Python wheels and frontend assets
          packages = with pkgs; [
            # Python and tooling
            python312
            uv

            # JS toolchain
            nodejs_22
            yarn
            sassc

            # Compilers and build helpers
            gcc
            pkg-config
            rustc
            cargo
            unzip
            git

            # Libraries commonly needed by Python deps (pillow, psycopg, etc.)
            cairo
            libjpeg_turbo
            libwebp
            libtiff
            freetype
            lcms2
            openjpeg
            zlib
            libffi
            openssl
            libpq

            # Databases/clients often used during development
            postgresql
            redis

            # i18n utilities for compilemessages
            gettext
          ];
        };

        checks.test = import ./nixos/tests/wger.nix {inherit pkgs self system;};
      }
    )
    // {
      nixosModules = {
        wger = import ./nixos/wger-module.nix;
      };
    };
}
