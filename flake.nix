{
  description = "Development environment and package for ss";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    md4c = {
      url = "github:mity/md4c/472c417005c2c71b8617de4f7b8d6b30411d78f4";
      flake = false;
    };
    tree-sitter-runtime = {
      url = "github:tree-sitter/tree-sitter/da6fe9beb4f7f67beb75914ca8e0d48ae48d6406";
      flake = false;
    };
    tree-sitter-bash = {
      url = "github:tree-sitter/tree-sitter-bash/a06c2e4415e9bc0346c6b86d401879ffb44058f7";
      flake = false;
    };
    tree-sitter-c = {
      url = "github:tree-sitter/tree-sitter-c/b780e47fc780ddc8da13afa35a3f4ed5c157823d";
      flake = false;
    };
    tree-sitter-cpp = {
      url = "github:tree-sitter/tree-sitter-cpp/8b5b49eb196bec7040441bee33b2c9a4838d6967";
      flake = false;
    };
    tree-sitter-css = {
      url = "github:tree-sitter/tree-sitter-css/dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f";
      flake = false;
    };
    tree-sitter-go = {
      url = "github:tree-sitter/tree-sitter-go/2346a3ab1bb3857b48b29d779a1ef9799a248cd7";
      flake = false;
    };
    tree-sitter-html = {
      url = "github:tree-sitter/tree-sitter-html/73a3947324f6efddf9e17c0ea58d454843590cc0";
      flake = false;
    };
    tree-sitter-java = {
      url = "github:tree-sitter/tree-sitter-java/e10607b45ff745f5f876bfa3e94fbcc6b44bdc11";
      flake = false;
    };
    tree-sitter-javascript = {
      url = "github:tree-sitter/tree-sitter-javascript/58404d8cf191d69f2674a8fd507bd5776f46cb11";
      flake = false;
    };
    tree-sitter-json = {
      url = "github:tree-sitter/tree-sitter-json/001c28d7a29832b06b0e831ec77845553c89b56d";
      flake = false;
    };
    tree-sitter-julia = {
      url = "github:tree-sitter/tree-sitter-julia/e0f9dcd180fdcfcfa8d79a3531e11d99e79321d3";
      flake = false;
    };
    tree-sitter-python = {
      url = "github:tree-sitter/tree-sitter-python/26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64";
      flake = false;
    };
    tree-sitter-rust = {
      url = "github:tree-sitter/tree-sitter-rust/77a3747266f4d621d0757825e6b11edcbf991ca5";
      flake = false;
    };
    tree-sitter-toml = {
      url = "github:tree-sitter-grammars/tree-sitter-toml/64b56832c2cffe41758f28e05c756a3a98d16f41";
      flake = false;
    };
    tree-sitter-typescript = {
      url = "github:tree-sitter/tree-sitter-typescript/75b3874edb2dc714fb1fd77a32013d0f8699989f";
      flake = false;
    };
    tree-sitter-yaml = {
      url = "github:tree-sitter-grammars/tree-sitter-yaml/a1c4812a73ec5e089de8e441fdea3a921e8d5079";
      flake = false;
    };
    tree-sitter-zig = {
      url = "github:tree-sitter-grammars/tree-sitter-zig/6479aa13f32f701c383083d8b28360ebd682fb7d";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = import ./release/nix/package.nix {
            inherit
              inputs
              pkgs
              self
              systems
              ;
          };
        }
      );

      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          ss = self.packages.${system}.default;
          python = pkgs.python312.withPackages (packages: [ packages.pyyaml ]);
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ ss ];
            packages = with pkgs; [
              git
              nodejs_22
              python
              zls
            ];

            # Entering the shell only describes the environment. `zig build`
            # stages the tree-sitter bundle itself, and picks the pinned
            # checkouts up from SS_TREE_SITTER_SOURCES instead of cloning.
            # The values come from the package's passthru so the shell and the
            # packaged binary cannot diverge.
            shellHook = ''
              # Refresh the symlink when the md4c pin moves, but never clobber
              # a real checkout made by scripts/setup-md4c.sh.
              if [ -L third_party/md4c ] || [ ! -e third_party/md4c ]; then
                ln -sfn ${inputs.md4c} third_party/md4c
              fi

              export SS_TREE_SITTER_SOURCES="${ss.treeSitterSources}"
              ${nixpkgs.lib.concatStringsSep "\n" (
                nixpkgs.lib.mapAttrsToList (name: value: ''export ${name}="${value}"'') ss.runtimeEnv
              )}
            '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
