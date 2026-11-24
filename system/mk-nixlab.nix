{ inputs }:

# Builds a whole nixlab from a set of vars: the Kubernetes render (nixidy),
# the NixOS configurations and the Colmena hive. flake.nix calls it with your
# vars.nix; the tests (tests/) call it with fake setups.
{ vars                     # contents of vars.nix
, extraVarsModules ? [ ]   # modules adding settings of your own (options), checked like nixlab's
, secretsFile              # SOPS secrets file for the nodes
, secretsDir ? null        # the cluster's Secrets: SOPS-encrypted manifests, <dir>/<namespace>/<name>.yaml
, appsDir ? null           # apps/, picked up automatically
, hardwareConfig           # hostname -> hardware-configuration.nix
, extraAppModules ? [ ]    # more nixidy app modules
, extraNixosModules ? [ ]  # more NixOS modules for every node
, chartsDir ? null         # your Helm charts: <dir>/<repo>/<chart>/default.nix (docs/adding-charts.md)
, extraSecrets ? [ ]       # more Kubernetes Secrets (format: k8s/secrets.nix)
, allowUnencryptedSecrets ? false # tests only: plaintext Kubernetes Secrets may be rendered
}:

let
  inherit (inputs) nixpkgs;
  inherit (nixpkgs) lib;
  # Where the Kubernetes manifests are rendered (CI, your workstation). Nodes
  # can be another platform: see nodeSystem.
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};

  # vars.nix against its typed options (vars/options.nix): wrong types are
  # reported by option name, unknown settings pointed out. allVars is yours
  # plus your extraVarsModules' settings.
  varsEval = import ./vars { inherit lib; } { inherit vars extraVarsModules; };
  allVars = varsEval.vars;

  # vars.nix mistakes (k8s/vars.nix `errors`): nothing renders or builds
  # until they're fixed, and every one is listed at once.
  errors = (import ./k8s/vars.nix allVars).errors;
  checked = x:
    if errors == [ ] then lib.foldr lib.warn (varsEval.check x) varsEval.warnings
    else throw "nixlab: please fix vars.nix:\n${lib.concatMapStrings (e: "  - ${e}\n") errors}";

  nixidyEnvs = builtins.mapAttrs (_: checked) (inputs.nixidy.lib.mkEnvs {
    inherit pkgs;
    extraSpecialArgs = {
      inherit inputs appsDir extraAppModules secretsDir extraSecrets allowUnencryptedSecrets;
      userVars = allVars;
      # Helpers for apps/ (nixlab.webApp, ...), see k8s/lib.nix.
      nixlab = import ./k8s/lib.nix { inherit (nixpkgs) lib; userVars = allVars; };
    };
    envs.homelab.modules = [
      ./k8s/nixidy.nix
      # Helm charts, one pinned file each (nixidy's chartsDir layout):
      # nixlab's in k8s/charts/, yours in chartsDir. Yours win on a clash, so
      # you can also hold back or move a platform chart. Modules get them as
      # charts.<repo>.<chart>.
      ({ lib, ... }: {
        nixidy.charts = lib.recursiveUpdate (lib.helm.mkChartAttrs ./k8s/charts)
          (lib.optionalAttrs (chartsDir != null) (lib.helm.mkChartAttrs chartsDir));
      })
    ];
  });
  nixidyEnv = nixidyEnvs.homelab;

  # A node's entry in allVars.nodes, found by its hostname: the attribute name
  # (master, worker1, ...) may differ from it.
  nodeByHostname = hostname: lib.findFirst (n: n.hostname == hostname)
    (throw "no node in allVars.nodes has hostname \"${hostname}\"") (lib.attrValues allVars.nodes);

  specialArgsFor = hostname: {
    inherit inputs hostname nixidyEnv secretsFile;
    userVars = allVars;
    nodeVars = nodeByHostname hostname;
    inherit (allVars) username;
  };

  # Each node's platform: allVars.nodes.<name>.system, x86_64-linux by default.
  nodeSystem = hostname: (nodeByHostname hostname).system or "x86_64-linux";

  modulesFor = hostname: [
    {
      networking.hostName = hostname;
      nixpkgs.hostPlatform = nodeSystem hostname;
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
  # The typed options, for docs/options/.
  varsOptions = varsEval.options;
  # A node's modules and special arguments, e.g. to boot it in a NixOS VM test.
  inherit modulesFor specialArgsFor;

  nixosConfigurations = builtins.mapAttrs (_: node: checked (
    nixpkgs.lib.nixosSystem {
      specialArgs = specialArgsFor node.hostname;
      modules = modulesFor node.hostname;
    })) allVars.nodes;

  colmena = {
    meta = {
      nixpkgs = pkgs;
      nodeSpecialArgs = builtins.mapAttrs (_: node: specialArgsFor node.hostname) allVars.nodes;
    };
  } // builtins.mapAttrs (_: node: {
    imports = modulesFor node.hostname;
    deployment = {
      # Its fixed address, else its mDNS name.
      targetHost = node.address or "${node.hostname}.local";
      targetUser = allVars.username;
      privilegeEscalationCommand = [ "sudo" "-S" ];
      tags = node.tags;
    };
  }) allVars.nodes;
}
