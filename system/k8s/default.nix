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
      default = k8sVars.layers.gitops;
      description = ''
        Install Argo CD and the parent "apps" Application on a fresh cluster.
        Runs once: as soon as the "apps" Application exists, Argo CD manages
        everything (itself included) and this does nothing.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ kubectl kubernetes-helm ]
      # Per-app backups: back one volume up now, restore one.
      ++ optionals k8sVars.backups.apps.enable (let t = import ./app-backups-tools.nix { inherit pkgs; }; in [ t.backupNow t.restore ]);

    # The age key into the cluster, for the nixlab-secrets app, which decrypts
    # secrets.yaml there (k8s/services/core/secrets.nix). Only the key: the
    # Secrets themselves come through git. Runs at every boot; idempotent.
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

    # Zero-touch bootstrap: Argo CD from the same nixidy render CI produces,
    # then the app-of-apps pointing at the rendered branch.
    # No Argo CD: k3s deploys nixlab's manifests from its auto-deploy directory.
    services.k3s.manifests = mkIf (!k8sVars.layers.gitops) appManifests;

    systemd.services.argocd-bootstrap = mkIf cfg.bootstrapArgo {
      description = "Install Argo CD on a fresh cluster";
      after = [ "k3s.service" "nixlab-age-key.service" ];
      wants = [ "k3s.service" "nixlab-age-key.service" ];
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

        if kubectl -n argocd get applications.argoproj.io apps >/dev/null 2>&1; then
          echo "Argo CD is already bootstrapped; it manages itself from here."
          exit 0
        fi

        cd ${nixidyEnv.environmentPackage}/argocd
        echo "Installing Argo CD..."
        kubectl apply --server-side --force-conflicts \
          -f Namespace-argocd.yaml $(printf -- '-f %s ' CustomResourceDefinition-*.yaml)
        kubectl wait --for=condition=Established --timeout=120s \
          $(printf -- '-f %s ' CustomResourceDefinition-*.yaml)
        kubectl apply --server-side --force-conflicts -f .

        echo "Creating the parent Application..."
        kubectl apply -f ${nixidyEnv.bootstrapPackage}/Application-apps.yaml
        echo "Done. Watch it converge: kubectl -n argocd get applications"
      '';
    };
  };
}
