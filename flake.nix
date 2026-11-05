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
    colmena.url = "github:zhaofengli/colmena";
    nixhelm.url = "github:farcaller/nixhelm";
    nix-kube-generators.url = "github:farcaller/nix-kube-generators";
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
      mkNixlab = import ./system/mk-nixlab.nix { inherit inputs; };
      # The `nix run` helpers, built for a given vars.nix (tools/).
      mkTools = { vars, mode ? "consumer" }: import ./tools { inherit pkgs nixidyCli vars mode; };
      # The whole flake of a homelab repo (template/flake.nix uses it).
      mkFlake = import ./system/mk-flake.nix { inherit inputs mkNixlab mkTools; };
    in
    {
      lib = { inherit mkFlake mkNixlab; };

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

      # `nix flake check` runs everything in tests/ (see tests/default.nix).
      checks.${system} = import ./tests { inherit inputs pkgs mkNixlab mkFlake mkTools; };

      devShells.${system}.default = pkgs.mkShell {
        packages = (with pkgs; [ age sops colmena kubectl wireguard-tools mkpasswd openssl crane ])
          ++ [ nixidyCli ];
      };
    };
}
