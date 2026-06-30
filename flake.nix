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

    in
    {
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
