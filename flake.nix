{
  description = "NixOS Homelab Configuration";

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
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      nixidyCli = inputs.nixidy.packages.x86_64-linux.default;

      # Everything (render, nodes, Colmena) from a set of vars. Your homelab:
      mkNixlab = import ./system/mk-nixlab.nix { inherit inputs; };
      homelab = mkNixlab {
        vars = import ./vars.nix;
        secretsFile = ./system/sops/secrets.yaml;
        appsDir = ./apps;
        hardwareConfig = hostname: ./hosts + "/${hostname}/hardware-configuration.nix";
      };

      # `nix run .#<name>` helpers, built from your vars (tools/).
      tools = import ./tools { inherit pkgs nixidyCli; vars = import ./vars.nix; };
    in
    {
      # Kubernetes manifests, rendered by CI (.github/workflows/k8s-render.yml)
      # into the branch Argo CD syncs from. Preview: nix run .#render
      nixidyEnvs.x86_64-linux = homelab.nixidyEnvs;
      inherit (homelab) nixosConfigurations colmena;

      lib = { inherit mkNixlab; };

      apps.x86_64-linux = builtins.mapAttrs (_: drv: {
        type = "app";
        program = "${drv}/bin/${drv.name}";
      }) tools;

      # `nix flake check` runs everything in tests/ (see tests/default.nix).
      checks.x86_64-linux = import ./tests { inherit inputs pkgs mkNixlab tools; }
        // tools;

      # `nix develop`: everything the docs use.
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = (with pkgs; [ age sops colmena kubectl wireguard-tools mkpasswd openssl crane ])
          ++ [ nixidyCli ];
      };
    };
}
