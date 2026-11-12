{ inputs, mkNixlab, mkTools }:

# The whole flake of a homelab repo (see template/flake.nix):
#   outputs = { nixlab, ... }: nixlab.lib.mkFlake { src = ./.; };
# Reads vars.nix, secrets.yaml, hosts/<hostname>/hardware-configuration.nix,
# apps/ and charts/ from `src`; each can be overridden.
{ src
, vars ? import (src + "/vars.nix")
, secretsFile ? src + "/secrets.yaml"
, appsDir ? src + "/apps"
  # Helm charts for your apps, one pinned file each (docs/adding-charts.md).
, chartsDir ? (if builtins.pathExists (src + "/charts") then src + "/charts" else null)
, hardwareConfig ? hostname: src + "/hosts/${hostname}/hardware-configuration.nix"
, extraNixosModules ? [ ]  # more NixOS modules for every node
, extraAppModules ? [ ]    # more nixidy app modules (or override nixlab's)
, allowUnencryptedSecrets ? false  # tests only: render a plaintext secretsFile
, extraSecrets ? [ ]       # more Kubernetes Secrets from SOPS:
                           #   [ { namespace; secretName; secretKey; sopsSecretName; } ]
}:

let
  system = "x86_64-linux";
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  inherit (pkgs) lib;

  lab = mkNixlab { inherit vars secretsFile appsDir chartsDir hardwareConfig extraNixosModules extraAppModules extraSecrets allowUnencryptedSecrets; };
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
    # Evaluation only: without its string context, the derivation path
    # doesn't make the check depend on (and so build) the whole system.
    (pkgs.writeText "node-${name}" (builtins.unsafeDiscardStringContext node.config.system.build.toplevel.drvPath))) lab.nixosConfigurations
  // tools;

  # `nix develop`: everything the docs use.
  devShells.${system}.default = pkgs.mkShell {
    packages = (with pkgs; [ age sops colmena kubectl wireguard-tools mkpasswd openssl crane ])
      ++ [ inputs.nixidy.packages.${system}.default ];
  };
}
