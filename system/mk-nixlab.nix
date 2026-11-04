{ inputs }:

# Builds a whole nixlab from a set of vars: the Kubernetes render (nixidy),
# the NixOS configurations and the Colmena hive. flake.nix calls it with your
# vars.nix; the tests (tests/) call it with fake setups.
{ vars                     # contents of vars.nix
, secretsFile              # SOPS secrets file for the nodes
, appsDir                  # apps/, picked up automatically
, hardwareConfig           # hostname -> hardware-configuration.nix
, extraAppModules ? [ ]    # more nixidy app modules
, extraNixosModules ? [ ]  # more NixOS modules for every node
}:

let
  inherit (inputs) nixpkgs;
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};

  nixidyEnvs = inputs.nixidy.lib.mkEnvs {
    inherit pkgs;
    charts = inputs.nixhelm.chartsDerivations.${system};
    extraSpecialArgs = {
      inherit inputs appsDir extraAppModules;
      userVars = vars;
      # Helpers for apps/ (nixlab.webApp, ...), see k8s/lib.nix.
      nixlab = import ./k8s/lib.nix { inherit (nixpkgs) lib; userVars = vars; };
    };
    envs.homelab.modules = [ ./k8s/nixidy.nix ];
  };
  nixidyEnv = nixidyEnvs.homelab;

  specialArgsFor = hostname: {
    inherit inputs hostname nixidyEnv secretsFile;
    userVars = vars;
    inherit (vars) username;
  };

  modulesFor = hostname: [
    {
      networking.hostName = hostname;
      nixpkgs.hostPlatform = system;
      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = builtins.attrValues (import ../overlays/default.nix);
    }
    ./node.nix
    (hardwareConfig hostname)
    inputs.sops-nix.nixosModules.sops
    inputs.disko.nixosModules.disko
    inputs.impermanence.nixosModules.impermanence
  ] ++ extraNixosModules;
in
{
  inherit nixidyEnvs nixidyEnv;

  nixosConfigurations = builtins.mapAttrs (_: node:
    nixpkgs.lib.nixosSystem {
      specialArgs = specialArgsFor node.hostname;
      modules = modulesFor node.hostname;
    }) vars.nodes;

  colmena = {
    meta = {
      nixpkgs = pkgs;
      nodeSpecialArgs = builtins.mapAttrs (_: node: specialArgsFor node.hostname) vars.nodes;
    };
  } // builtins.mapAttrs (_: node: {
    imports = modulesFor node.hostname;
    deployment = {
      targetHost = "${node.hostname}.local";
      targetUser = vars.username;
      privilegeEscalationCommand = [ "sudo" "-S" ];
      tags = node.tags;
    };
  }) vars.nodes;
}
