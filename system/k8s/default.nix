# nixidyEnv, userVars and extraSecrets are special arguments from mkNixlab
# (system/mk-nixlab.nix).
{ config, lib, pkgs, nixidyEnv, userVars, extraSecrets ? [ ], ... }:

# Workloads are deployed by Argo CD from the rendered branch (see nixidy.nix).
# The host pushes SOPS secrets into the cluster (they must never go through
# git) and, on a fresh cluster, installs Argo CD once. With gitops.enable =
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
          echo ---; cat "$f"
        done
      } > $out
    '';
  # nixidy's own entries: the app-of-apps (Argo CD Application objects) and its bootstrap.
  }) (removeAttrs nixidyEnv.config.applications [ "apps" "__bootstrap" ]);
  secrets = import ./secrets.nix { inherit lib userVars; } ++ extraSecrets;

  # One Kubernetes Secret per (namespace, secretName), holding all its keys.
  grouped = groupBy (s: "${s.namespace}/${s.secretName}") secrets;
  namespaces = unique (map (s: s.namespace) secrets);

  applySecret = entries:
    let first = head entries;
    in ''
      echo "Applying secret ${first.namespace}/${first.secretName}"
      kubectl create secret generic ${escapeShellArg first.secretName} \
        --namespace ${escapeShellArg first.namespace} \
        ${concatMapStringsSep " \\\n    " (s:
          if s ? value
          then "--from-literal=${escapeShellArg "${s.secretKey}=${s.value}"}"
          else "--from-file=${escapeShellArg s.secretKey}=${config.sops.secrets.${s.sopsSecretName}.path}")
        entries} \
        --dry-run=client -o yaml | kubectl apply -f -
    '';
in {
  options.modules.k8s = {
    enable = mkEnableOption "pushing SOPS secrets into the k3s cluster";
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
    environment.systemPackages = with pkgs; [ kubectl kubernetes-helm ];

    # Re-push when a secret's value changes.
    sops.secrets = genAttrs (unique (map (s: s.sopsSecretName) (filter (s: s ? sopsSecretName) secrets)))
      (_: { restartUnits = [ "k8s-secrets.service" ]; });

    systemd.services.k8s-secrets = {
      description = "Push SOPS secrets into Kubernetes";
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.kubectl ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      restartTriggers = [ (builtins.toJSON secrets) ];
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

        ${concatMapStringsSep "\n" (ns: ''
          kubectl get namespace ${ns} >/dev/null 2>&1 || kubectl create namespace ${ns}
        '') namespaces}

        ${concatMapStringsSep "\n" applySecret (attrValues grouped)}
      '';
    };

    # Zero-touch bootstrap: Argo CD from the same nixidy render CI produces,
    # then the app-of-apps pointing at the rendered branch.
    # No Argo CD: k3s deploys nixlab's manifests from its auto-deploy directory.
    services.k3s.manifests = mkIf (!k8sVars.layers.gitops) appManifests;

    systemd.services.argocd-bootstrap = mkIf cfg.bootstrapArgo {
      description = "Install Argo CD on a fresh cluster";
      after = [ "k3s.service" "k8s-secrets.service" ];
      wants = [ "k3s.service" "k8s-secrets.service" ];
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
