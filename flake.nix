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
    { self, nixpkgs, sops-nix, disko, impermanence, ... }@inputs:
    let
      vars = import ./vars.nix;

      mkSystemModules = hostname:
        [
          {
            networking.hostName = hostname;
            nixpkgs.config.allowUnfree = true;
            nixpkgs.overlays = builtins.attrValues (import ./overlays/default.nix);
          }
          ./modules/system/node.nix
          (./. + "/hosts/${hostname}/hardware-configuration.nix")
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
          impermanence.nixosModules.impermanence
        ];

      mkSystem = hostname:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit inputs;
            username = vars.username;
            inherit hostname;
          };
          modules = (mkSystemModules hostname) ++ [{ nixpkgs.hostPlatform = "x86_64-linux"; }];
        };

      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      nixidyCli = inputs.nixidy.packages.x86_64-linux.default;

      # `nix run .#<name>` helpers (scripts/)
      mkScript = name: runtimeInputs: text:
        pkgs.writeShellApplication { inherit name runtimeInputs text; };
      scripts = {
        init = mkScript "nixlab-init"
          (with pkgs; [ age sops openssh openssl wireguard-tools mkpasswd nix gnused ])
          (builtins.readFile ./scripts/init.sh);
        new-app = mkScript "nixlab-new-app" [ pkgs.crane pkgs.git ]
          (builtins.readFile ./scripts/new-app.sh);
        add-wg-user = mkScript "nixlab-add-wg-user" (with pkgs; [ sops wireguard-tools nix ])
          ''exec bash modules/system/sops/add-wg-user.sh "$@"'';
        render = mkScript "nixlab-render" [ nixidyCli ] ''
          nixidy build .#homelab "$@"
          echo "Rendered manifests: ./result (one directory per app)"
        '';
      };
    in
    {
      apps.x86_64-linux = builtins.mapAttrs (_: drv: {
        type = "app";
        program = "${drv}/bin/${drv.name}";
      }) scripts;

      # `nix flake check`: the default render, and shellcheck of the helpers
      # (writeShellApplication runs it at build time). More in .github/workflows/ci.yml.
      checks.x86_64-linux = {
        render = self.nixidyEnvs.x86_64-linux.homelab.environmentPackage;
      } // builtins.mapAttrs (_: drv: drv) scripts;

      # `nix develop`: everything the docs use.
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = (with pkgs; [ age sops colmena kubectl wireguard-tools mkpasswd openssl crane ])
          ++ [ nixidyCli ];
      };

      # Kubernetes manifests, rendered by CI (.github/workflows/k8s-render.yml)
      # into the branch Argo CD syncs from. Preview locally:
      #   nix run .#render
      nixidyEnvs.x86_64-linux = inputs.nixidy.lib.mkEnvs {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        charts = inputs.nixhelm.chartsDerivations.x86_64-linux;
        # nixlab: helpers for apps/ (nixlab.webApp, ...), see modules/system/k8s/lib.nix
        extraSpecialArgs = {
          inherit inputs;
          nixlab = import ./modules/system/k8s/lib.nix { inherit (nixpkgs) lib; };
        };
        envs.homelab.modules = [ ./modules/system/k8s/nixidy.nix ];
      };

      nixosConfigurations =
        builtins.mapAttrs (name: node: mkSystem node.hostname) vars.nodes;

      colmena = {
        meta = {
          nixpkgs = nixpkgs.legacyPackages.x86_64-linux;
          specialArgs = { inherit inputs; };
        };
      }
      // (builtins.mapAttrs (name: node: {
        _module.args = {
          username = vars.username;
          hostname = node.hostname;
        };
        imports = (mkSystemModules node.hostname)
          ++ [{ nixpkgs.hostPlatform = "x86_64-linux"; }];

        deployment = {
          targetHost = "${node.hostname}.local";
          targetUser = vars.username;
          privilegeEscalationCommand = [ "sudo" "-S" ];
          tags = node.tags;
        };
      }) vars.nodes);
    };
}
