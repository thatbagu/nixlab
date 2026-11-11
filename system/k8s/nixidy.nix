# Special arguments (from mkNixlab, system/mk-nixlab.nix): userVars
# (vars.nix), appsDir (apps/), extraAppModules (more app modules, e.g. tests).
{ lib, userVars, appsDir, extraAppModules ? [ ], ... }:

let
  vars = import ./vars.nix userVars;

  # Every app in apps/ is picked up automatically: apps/<name>.nix or
  # apps/<name>/default.nix. Names starting with "_" are skipped (examples,
  # disabled apps).
  appModules = lib.optionals (appsDir != null && builtins.pathExists appsDir) (lib.mapAttrsToList (name: _: appsDir + "/${name}") (
    lib.filterAttrs (name: type:
      !lib.hasPrefix "_" name
      && ((type == "regular" && lib.hasSuffix ".nix" name)
        || (type == "directory" && builtins.pathExists (appsDir + "/${name}/default.nix"))))
      (builtins.readDir appsDir)));
in

# nixidy environment for the homelab cluster. Each module defines its own
# `applications.<name>`: the platform (networking, storage, DNS, TLS, VPN) in
# ./services, your apps in apps/ at the repo root.
#
# On every push to main, .github/workflows/k8s-render.yml renders this env and
# commits the YAML to the rendered branch (vars.renderedBranch), which Argo CD
# syncs from.
# Preview locally with: nix run .#render
{
  imports = [
    ./argocd.nix
    ./services/core/longhorn.nix
    ./services/core/metallb.nix
    ./services/core/gateway.nix
    ./services/core/secrets.nix
    ./services/core/edge.nix
    ./services/core/backups.nix
    ./services/core/monitoring.nix
    ./services/dns/pihole.nix
    ./services/dns/externaldns.nix
    ./services/dns/cert-manager.nix
    ./services/dns/ddns.nix
    ./services/vpn/wireguard.nix
    # Built-in optional apps (vars.nix: nextcloud.enable, signalProxy.enable).
    ./apps/nextcloud.nix
    ./apps/signal-proxy.nix
    ./apps/telegram-proxy.nix
  ] ++ appModules ++ extraAppModules;

  _module.args.vars = vars;

  # Extend every application with a sync wave and homelab defaults.
  nixidy.applicationImports = [
    ({ config, lib, ... }: {
      options.syncWave = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Argo CD sync wave of the Application within the app-of-apps.";
      };
      config = {
        annotations."argocd.argoproj.io/sync-wave" = toString config.syncWave;
        syncPolicy.syncOptions = {
          createNamespace = lib.mkDefault true;
          pruneLast = lib.mkDefault true;
        };
      };
    })
  ];

  nixidy.target = {
    repository = vars.gitRepository;
    branch = vars.renderedBranch;
    rootPath = "./";
  };

  # Every app auto-syncs, self-heals and prunes unless it opts out.
  nixidy.defaults.syncPolicy.autoSync = {
    enable = true;
    selfHeal = true;
    prune = true;
  };

  # Never let Argo delete storage, CRDs (would cascade to every CR) or
  # namespaces, whether by pruning or by deleting an Application.
  # Appends to existing sync-options (e.g. ServerSideApply=true on large CRDs).
  nixidy.objectTransforms.protect-stateful = {
    match.kind = [ "PersistentVolumeClaim" "CustomResourceDefinition" "Namespace" ];
    update = obj:
      let
        key = "argocd.argoproj.io/sync-options";
        existing = obj.metadata.annotations.${key} or "";
        options = lib.filter (o: o != "") (lib.splitString "," existing)
          ++ [ "Prune=false" "Delete=false" ];
      in {
        metadata.annotations.${key} = lib.concatStringsSep "," (lib.unique options);
      };
  };
}
