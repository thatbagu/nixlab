{ inputs, mkNixlab, mkTools }:

# The whole flake of a homelab repo (see template/flake.nix):
#   outputs = { nixlab, ... }: nixlab.lib.mkFlake { src = ./.; };
# Reads vars.nix, secrets.yaml, hosts/<hostname>/hardware-configuration.nix
# and apps/ from `src`; each can be overridden.
{ src
, vars ? import (src + "/vars.nix")
, secretsFile ? src + "/secrets.yaml"
, appsDir ? src + "/apps"
, hardwareConfig ? hostname: src + "/hosts/${hostname}/hardware-configuration.nix"
, extraNixosModules ? [ ]  # more NixOS modules for every node
, extraAppModules ? [ ]    # more nixidy app modules (or override nixlab's)
, extraSecrets ? [ ]       # more Kubernetes Secrets pushed from SOPS:
                           #   [ { namespace; secretName; secretKey; sopsSecretName; } ]
}:

let
  system = "x86_64-linux";
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  inherit (pkgs) lib;

  lab = mkNixlab { inherit vars secretsFile appsDir hardwareConfig extraNixosModules extraAppModules extraSecrets; };
  tools = mkTools { inherit vars; mode = "consumer"; };
in
{
  # Kubernetes manifests, rendered by CI (.github/workflows/k8s-render.yml)
  # into the branch Argo CD syncs from. Preview: nix run .#render
  nixidyEnvs.${system} = lab.nixidyEnvs;
  inherit (lab) nixosConfigurations colmena;

  # nix run .#init / .#add-wg-user / .#new-app / .#render / .#update
  apps.${system} = builtins.mapAttrs (_: drv: {
    type = "app";
    program = "${drv}/bin/${drv.name}";
  }) tools;

  # `nix flake check`: your manifests render and every node's configuration
  # evaluates (CI also builds them; see .github/workflows/ci.yml).
  checks.${system} = {
    manifests = lab.nixidyEnv.environmentPackage;
  } // lib.mapAttrs' (name: node: lib.nameValuePair "node-${name}"
    (pkgs.writeText "node-${name}" node.config.system.build.toplevel.drvPath)) lab.nixosConfigurations
  // tools;

  # `nix develop`: everything the docs use.
  devShells.${system}.default = pkgs.mkShell {
    packages = (with pkgs; [ age sops colmena kubectl wireguard-tools mkpasswd openssl crane ])
      ++ [ inputs.nixidy.packages.${system}.default ];
  };
}
