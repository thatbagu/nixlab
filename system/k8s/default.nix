# nixidyEnv and userVars are special arguments from mkNixlab
# (system/mk-nixlab.nix).
{ config, lib, pkgs, nixidyEnv, userVars, ... }:

# Workloads are deployed by Argo CD from the rendered branch (see nixidy.nix),
# their Secrets included (decrypted in the cluster, see services/core/
# secrets.nix). The host places the age key in the cluster and, on a fresh
# cluster, installs Argo CD once. With gitops.enable =
# false there's no Argo CD: k3s applies the rendered manifests itself.
with lib;
let
  cfg = config.modules.k8s;
  k8sVars = import ./vars.nix userVars;
  engine = (import ./gitops { inherit lib; }).selected k8sVars;

  # Without Argo CD: one manifest per app for k3s' auto-deploy directory, in
  # the order Argo CD would apply it (namespace, CRDs, the rest). k3s applies
  # them, re-applies on change and retries until what they need exists.
  appManifests = mapAttrs' (name: app: nameValuePair "nixlab-${name}" {
    source = pkgs.runCommand "nixlab-${name}.yaml" { } ''
      dir=${nixidyEnv.environmentPackage}/${name}
      {
        printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' ${escapeShellArg app.namespace}
        for f in "$dir"/CustomResourceDefinition-*.yaml; do [ -e "$f" ] && { echo ---; cat "$f"; }; done
        for f in "$dir"/*.yaml; do
          case "$f" in */CustomResourceDefinition-*) continue ;; esac
          # Charts' test hooks (helm test): Argo CD skips them, so does this.
          grep -q 'helm.sh/hook: test' "$f" && continue
          echo ---; cat "$f"
        done
      } > $out
      ${optionalString cfg.stripImageDigests "sed -i -E 's/@sha256:[0-9a-f]{64}//' $out"}
    '';
  # nixidy's own entries: the app-of-apps (Argo CD Application objects) and its bootstrap.
  }) (removeAttrs nixidyEnv.config.applications [ "apps" "__bootstrap" ]);
in {
  options.modules.k8s = {
    enable = mkEnableOption "the master's part of the cluster setup (age key, Argo CD bootstrap)";
    stripImageDigests = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      description = ''
        Only for offline VM tests (without Argo CD): drop the registry
        digests from the manifests k3s applies, so images preloaded into k3s
        (which keep only their tag) match. Real nodes keep the digests.
      '';
    };
    bootstrapArgo = mkOption {
      type = types.bool;
      default = k8sVars.argocd;
      description = ''
        Install Argo CD and the parent "apps" Application on a fresh cluster.
        Runs once: as soon as the "apps" Application exists, Argo CD manages
        everything (itself included) and this does nothing.
      '';
    };
    bootstrapFlux = mkOption {
      type = types.bool;
      default = k8sVars.flux;
      description = ''
        Install Flux and its Kustomizations (flux-apps/ in the render) on a
        fresh cluster. Runs once: as soon as the root "apps" Kustomization
        exists, Flux manages everything (itself included) and this does
        nothing.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [ {
    environment.systemPackages = with pkgs; [ kubectl kubernetes-helm ]
      # `flux get kustomizations`, `flux resume kustomization longhorn`, ...
      # The GitOps engine's CLI (flux, ...).
      ++ optionals (engine != null) (engine.cli pkgs)
      # Per-app backups: back one volume up now, restore one.
      ++ optionals k8sVars.backups.apps.enable (let
        # Nextcloud's database is backed up as dumps (with backups on).
        t = import ./app-backups-tools.nix { inherit pkgs; nextcloud = k8sVars.features.nextcloud; };
      in [ t.backupNow t.restore t.restoreAll ] ++ optional k8sVars.features.nextcloud t.restoreNextcloudDb)
      # After a node's reinstall: forget its old Longhorn disk (nix run .#reinstall).
      ++ optional k8sVars.layers.longhorn (import ./longhorn-tools.nix { inherit pkgs; })
      # Backups of volumes that no longer exist (Longhorn keeps them for good).
      ++ optional (k8sVars.layers.longhorn && k8sVars.backups.enable) (import ./longhorn-prune.nix { inherit pkgs; });

    # The age key into the cluster, for the nixlab-secrets app, which decrypts
    # secrets.yaml there (k8s/services/core/secrets.nix). Only the key: the
    # Secrets themselves come through git. Runs at every boot; idempotent.
    # Finished pods their controller already replaced (after a node restart).
    systemd.services.nixlab-gc-failed-pods = {
      description = "Delete finished pods that were replaced";
      after = [ "k3s.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.ExecStart = getExe (import ./failed-pods.nix { inherit pkgs; });
    };
    systemd.timers.nixlab-gc-failed-pods = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "15min"; OnUnitActiveSec = "1h"; };
    };

    systemd.services.nixlab-age-key = {
      description = "Place the SOPS age key in the cluster (for nixlab-secrets)";
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.kubectl ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
      };
      script = ''
        set -o pipefail
        until kubectl get --raw /readyz >/dev/null 2>&1; do
          echo "Waiting for the Kubernetes API..."
          sleep 5
        done
        kubectl get namespace nixlab-secrets >/dev/null 2>&1 || kubectl create namespace nixlab-secrets
        kubectl -n nixlab-secrets create secret generic age-key \
          --from-file=keys.txt=${config.sops.age.keyFile} --dry-run=client -o yaml \
          | kubectl apply --server-side --field-manager=nixlab-age-key --force-conflicts -f - >/dev/null
        echo "age key in place"
      '';
    };

    # No GitOps: k3s deploys nixlab's manifests from its auto-deploy directory.
    services.k3s.manifests = mkIf (!k8sVars.layers.gitops) appManifests;
  }

  # Zero-touch bootstrap: the GitOps engine (gitops/<engine>) installs
  # itself from the same render CI produces, once, on a fresh cluster.
  (mkIf (engine != null && cfg.${engine.bootstrapOption}) (let b = engine.bootstrap { inherit pkgs nixidyEnv k8sVars; }; in {
    systemd.services.${b.name} = {
      inherit (b) description path script;
      after = [ "k3s.service" "nixlab-age-key.service" ];
      wants = [ "k3s.service" "nixlab-age-key.service" ];
      wantedBy = [ "multi-user.target" ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
      };
    };
  }))
  ]);
}
