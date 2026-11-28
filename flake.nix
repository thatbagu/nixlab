{
  description = "nixlab: a NixOS + k3s homelab platform. Start a homelab with: nix flake init -t github:thatbagu/nixlab";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence.url = "github:nix-community/impermanence";
    # Continuous deploys of the nodes (autoUpgrade.mode = "continuous").
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    colmena.url = "github:zhaofengli/colmena";
    nixidy = {
      url = "github:arnarg/nixidy/v0.23.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      nixidyCli = inputs.nixidy.packages.${system}.default;

      # Everything (render, nodes, Colmena) from a set of vars.
      mkNixlab = import ./lib/mk-nixlab.nix { inherit inputs; };
      # The `nix run` helpers, built for a given vars.nix (tools/).
      # (They read the typed settings, like the rest of nixlab: modules/vars.)
      mkTools = { vars, mode ? "consumer", paths ? { }, installerImage ? null, secretsData ? null, appsData ? null }: import ./tools {
        inherit pkgs nixidyCli mode paths installerImage secretsData appsData;
        vars = (import ./modules/vars { inherit (pkgs) lib; } { inherit vars; }).vars;
      };
      # The whole flake of a homelab repo (template/flake.nix uses it).
      mkFlake = import ./lib/mk-flake.nix { inherit inputs mkNixlab mkTools; };
    in
    {
      lib = { inherit mkFlake mkNixlab mkTools; };

      # For machines outside the lab: the VPS end of the tunnel (vars.nix tunnel).
      nixosModules.tunnel-server = ./modules/nixos/tunnel/server.nix;

      # nix flake init -t github:thatbagu/nixlab
      templates.default = {
        path = ./template;
        description = "A homelab built with nixlab";
        welcomeText = ''
          # Your nixlab homelab

          Next: `nix run .#init` (keys and encrypted secrets), fill in `vars.nix`,
          add each node's `hosts/<hostname>/hardware-configuration.nix`, push.
          Guide: https://thatbagu.github.io/nixlab/getting-started.html
        '';
      };

      # For nixlab itself: the weekly update (platform digests, VM test images).
      apps.${system}.update = let tool = (mkTools { vars = import ./template/vars.nix; mode = "library"; }).update; in {
        type = "app";
        program = "${tool}/bin/${tool.name}";
      };

      # docs/options/: every vars.nix setting by topic, from modules/vars/options.nix.
      # Regenerate: rm -r docs/options && cp -r "$(nix build --print-out-paths .#options-doc)" docs/options && chmod -R u+w docs/options
      packages.${system}.options-doc = import ./modules/vars/doc.nix { inherit pkgs; };

      # `nix flake check` runs everything in tests/ (see tests/default.nix).
      checks.${system} = import ./tests { inherit inputs pkgs mkNixlab mkFlake mkTools; };

      devShells.${system}.default = pkgs.mkShell {
        packages = (with pkgs; [ age sops colmena kubectl wireguard-tools mkpasswd openssl crane ])
          ++ [ nixidyCli ];
      };
    };
}
