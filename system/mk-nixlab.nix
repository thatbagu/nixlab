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
  # Without Kubernetes, every app must run natively.
  kube = allVars.kubernetes.enable or true;
  needsKubernetes = env: lib.attrNames (lib.filterAttrs (_: a:
    lib.any (o: lib.elem o.kind [ "Deployment" "StatefulSet" "DaemonSet" ]) a.objects) env.config.applications);
  checked = x:
    if errors != [ ] then throw "nixlab: please fix vars.nix:\n${lib.concatMapStrings (e: "  - ${e}\n") errors}"
    # (checked also wraps the nodes' configurations: only the render has apps.)
    else if !kube && x ? environmentPackage && needsKubernetes x != [ ] then
      throw "nixlab: kubernetes.enable = false, but these apps run on Kubernetes: ${lib.concatStringsSep ", " (needsKubernetes x)}. Give them runtime = \"native\" (nixlab.app), or turn Kubernetes on."
    else lib.foldr lib.warn (varsEval.check x) varsEval.warnings;

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
    inherit inputs hostname nixidyEnv secretsFile secretsDir;
    userVars = allVars;
    nodeVars = nodeByHostname hostname;
    inherit (allVars) username;
  };

  # Each node's platform: allVars.nodes.<name>.system, x86_64-linux by default.
  nodeSystem = hostname: (nodeByHostname hostname).system or "x86_64-linux";

  # A node's hardware configuration, or what to do when it's missing.
  # Nix only sees files git knows: a file you made but didn't `git add` is
  # missing too.
  hardwareConfigChecked = hostname:
    let p = hardwareConfig hostname; in
    if builtins.isPath p && !(builtins.pathExists p) then
      throw ("nixlab: hosts/${hostname}/hardware-configuration.nix is missing (a node in vars.nix has hostname = \"${hostname}\").\n"
        + "  If you made it: git add it (Nix only sees files git knows).\n"
        + "  If not: nixlab install ${hostname} root@<its IP> reads it off the machine, or run nixos-generate-config --show-hardware-config there.")
    else p;

  modulesFor = hostname: [
    {
      networking.hostName = hostname;
      nixpkgs.hostPlatform = nodeSystem hostname;
      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = builtins.attrValues (import ../overlays/default.nix);
    }
    ./node.nix
    (hardwareConfigChecked hostname)
    inputs.sops-nix.nixosModules.sops
    inputs.disko.nixosModules.disko
    inputs.impermanence.nixosModules.impermanence
    inputs.comin.nixosModules.default
  ]
  # The NixOS modules of the native apps assigned to this node: here, from
  # the hostname, not as the node module's imports (those can't depend on
  # module arguments, which tests set per machine).
  ++ map (a: a.nixos) (builtins.filter (a: a.node == hostname && a.nixos != null)
    (builtins.attrValues nixidyEnv.config.nixlab.nativeApps))
  ++ extraNixosModules;
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
