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

      # `nix run .#<name>` helpers (scripts/). They prompt, create keys and
      # call sops, which Nix evaluation can't do, so they're small shell
      # scripts (shellchecked at build time).
      mkScript = name: runtimeInputs: text:
        pkgs.writeShellApplication { inherit name runtimeInputs text; };
      scripts = {
        init = mkScript "nixlab-init"
          (with pkgs; [ age sops openssh openssl wireguard-tools mkpasswd nix gnused ])
          (builtins.readFile ./scripts/init.sh);
        new-app = mkScript "nixlab-new-app" [ pkgs.crane pkgs.git ]
          (builtins.readFile ./scripts/new-app.sh);
        add-wg-user = mkScript "nixlab-add-wg-user" (with pkgs; [ sops wireguard-tools nix ])
          ''exec bash system/sops/add-wg-user.sh "$@"'';
        render = mkScript "nixlab-render" [ nixidyCli ] ''
          nixidy build .#homelab "$@"
          echo "Rendered manifests: ./result (one directory per app)"
        '';
      };
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
      }) scripts;

      # `nix flake check` runs everything in tests/ (see tests/default.nix).
      checks.x86_64-linux = import ./tests { inherit inputs pkgs mkNixlab; }
        // builtins.mapAttrs (_: drv: drv) scripts;

      # `nix develop`: everything the docs use.
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = (with pkgs; [ age sops colmena kubectl wireguard-tools mkpasswd openssl crane ])
          ++ [ nixidyCli ];
      };
    };
}
