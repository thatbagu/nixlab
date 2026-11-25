{ inputs, mkNixlab, mkTools }:

# The whole flake of a homelab repo (see template/flake.nix):
#   outputs = { nixlab, ... }: nixlab.lib.mkFlake { src = ./.; };
# Reads vars.nix, secrets.yaml, secrets/k8s/, hosts/<hostname>/hardware-configuration.nix,
# apps/ and charts/ from `src`; each can be overridden.
{ src
  # vars.nix, or vars.toml (the same settings in TOML, for repos without Nix
  # syntax: docs/configuration.md).
, varsFile ? (if builtins.pathExists (src + "/vars.nix") || !(builtins.pathExists (src + "/vars.toml")) then "vars.nix" else "vars.toml")
, vars ? (if varsFile == "vars.toml" then builtins.fromTOML (builtins.readFile (src + "/vars.toml")) else import (src + "/vars.nix"))
, secretsFile ? src + "/secrets.yaml"
  # Kubernetes Secrets, SOPS-encrypted manifests: <dir>/<namespace>/<name>.yaml
, secretsDir ? src + "/secrets/k8s"
, appsDir ? src + "/apps"
  # Helm charts for your apps, one pinned file each (docs/adding-charts.md).
, chartsDir ? (if builtins.pathExists (src + "/charts") then src + "/charts" else null)
, hardwareConfig ? hostname: src + "/hosts/${hostname}/hardware-configuration.nix"
, extraNixosModules ? [ ]  # more NixOS modules for every node
, extraAppModules ? [ ]    # more nixidy app modules (or override nixlab's)
, extraVarsModules ? [ ]   # settings of your own for vars.nix (options), read in apps/ as nixlab.vars.<name>
, allowUnencryptedSecrets ? false  # tests only: render plaintext Kubernetes Secrets
, extraSecrets ? [ ]       # more Kubernetes Secrets (secretsDir/<namespace>/<secretName>.yaml):
                           #   [ { namespace; secretName; secretKey; } ]
}:

let
  system = "x86_64-linux";
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  inherit (pkgs) lib;

  lab = mkNixlab { inherit vars secretsFile secretsDir appsDir chartsDir hardwareConfig extraNixosModules extraAppModules extraVarsModules extraSecrets allowUnencryptedSecrets; };
  tools = mkTools {
    inherit vars;
    mode = "consumer";
    paths.vars = varsFile;
    secretsData = { inherit (lab.nixidyEnv.config.nixlab.secrets) declared values; };
    appsData = import ./apps-data.nix { inherit lib; config = lab.nixidyEnv.config; };
  };
in
{
  # Kubernetes manifests, rendered by CI (.github/workflows/k8s-render.yml)
  # into the branch Argo CD syncs from. Preview: nixlab render
  nixidyEnvs.${system} = lab.nixidyEnvs;
  inherit (lab) nixosConfigurations colmena;

  # nix run . -- <command> (nixlab <command>), or nix run .#<command> as before.
  apps.${system} = let apps = builtins.mapAttrs (_: drv: {
    type = "app";
    program = "${drv}/bin/${drv.name}";
  }) tools; in apps // {
    default = apps.nixlab;
    # Your master as a local VM (system/local-vm.nix).
    vm = { type = "app"; program = "${import ./local-vm.nix { inherit lib pkgs lab vars; }}/bin/nixlab-vm"; };
  };

  # `nix flake check`: your manifests render and every node's configuration
  # evaluates (CI also builds them; see .github/workflows/ci.yml).
  checks.${system} = {
    manifests = lab.nixidyEnv.environmentPackage;
  } // lib.mapAttrs' (name: node: lib.nameValuePair "node-${name}"
    # Evaluation only: without its string context, the derivation path
    # doesn't make the check depend on (and so build) the whole system.
    (pkgs.writeText "node-${name}" (builtins.unsafeDiscardStringContext node.config.system.build.toplevel.drvPath))) lab.nixosConfigurations
  // tools;

  # `nix develop`: nixlab, and everything the docs use.
  devShells.${system}.default = pkgs.mkShell {
    packages = (with pkgs; [ age sops colmena kubectl wireguard-tools mkpasswd openssl crane ])
      ++ [ inputs.nixidy.packages.${system}.default tools.nixlab ];
  };
}
