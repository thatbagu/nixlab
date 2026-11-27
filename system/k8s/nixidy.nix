# Special arguments (from mkNixlab, system/mk-nixlab.nix): userVars
# (vars.nix), appsDir (apps/), extraAppModules (more app modules, e.g. tests).
{ lib, userVars, appsDir, extraAppModules ? [ ], ... }:

let
  vars = import ./vars.nix userVars;
  gitops = import ./gitops { inherit lib; };
  engine = gitops.selected vars;

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
# (or Flux, flux.nix) syncs from.
# Preview locally with: nixlab render
{
  imports = [
    # The GitOps engines' controllers (each self-gated: gitops/default.nix).
    ./gitops/argocd/app.nix
    ./gitops/flux/app.nix
    ./services/core/longhorn.nix
    ./network/cilium-app.nix
    ./native-apps.nix
    ./services/core/metallb.nix
    ./services/core/gateway.nix
    ./services/core/secrets.nix
    ./services/core/edge.nix
    ./services/core/backups.nix
    ./services/core/app-backups.nix
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
    ./apps/status-page.nix
    ./apps/auth.nix
  ] ++ appModules ++ extraAppModules;

  _module.args.vars = vars;

  # Extend every application with a sync wave and homelab defaults.
  nixidy.applicationImports = [
    # Every app (the app-of-apps too) keeps retrying a failed sync, every
    # minute at most, instead of giving up after Argo CD's 5 attempts: on a
    # fresh cluster the waves wait for images, certificates and each other
    # for a while. The app-of-apps creates the next wave's Applications only
    # once the previous wave is healthy, so its wait between attempts adds
    # straight to how long a new cluster takes (with 5 minutes, often half
    # an hour; the bootstrap VM tests timed out on it).
    ({ lib, ... }: {
      syncPolicy.retry = lib.mkDefault {
        limit = -1;
        backoff = { duration = "15s"; factor = 2; maxDuration = "1m"; };
      };
    })
    ({ config, lib, ... }: {
      options.syncWave = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Argo CD sync wave of the Application within the app-of-apps.";
      };
      options.sopsDecrypt = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "The app carries SOPS-encrypted Secrets (services/core/secrets.nix): Flux decrypts them.";
      };
      options.deployPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          The directory of the render the GitOps controller deploys, when it
          isn't the app's own (output.path): e.g. the app's objects plus extra
          files next to them (services/core/secrets.nix).
        '';
      };
      options.syncAlone = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Flux: nothing waits for this app and it waits for nothing; it retries
          until what it needs exists (e.g. namespaces other apps create).
        '';
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


  # Never let the GitOps controller delete storage, CRDs (would cascade to
  # every CR) or namespaces, whether by pruning or by deleting its app: each
  # engine says how (gitops/<engine>). Argo CD's annotation is always there
  # (it predates the engines and does nothing without Argo CD).
  nixidy.objectTransforms.protect-stateful = {
    match.kind = [ "PersistentVolumeClaim" "CustomResourceDefinition" "Namespace" ];
    update = obj: {
      metadata.annotations = gitops.engines.argocd.protect obj
        // lib.optionalAttrs (engine != null && vars.gitopsEngine != "argocd") (engine.protect obj);
    };
  };
}
