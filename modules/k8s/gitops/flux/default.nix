# Flux as nixlab's GitOps engine: the interface is in ../default.nix.
{ lib }:

{
  name = "Flux";
  # Flux itself and flux-apps/, as a nixidy module (self-gated on vars.flux).
  module = ./app.nix;

  # Never let Flux delete storage, CRDs or namespaces: not by pruning, and
  # not when their Kustomization goes.
  protect = _obj: { "kustomize.toolkit.fluxcd.io/prune" = "disabled"; };

  # The master's one-time install on a fresh cluster (modules/k8s/default.nix).
  bootstrapOption = "bootstrapFlux";
  bootstrap = { pkgs, nixidyEnv, k8sVars }: {
    name = "flux-bootstrap";
    description = "Install Flux on a fresh cluster";
    path = [ pkgs.kubectl ];
    script = let env = nixidyEnv.environmentPackage; in ''
      set -o pipefail

      until kubectl get --raw /readyz >/dev/null 2>&1; do
        echo "Waiting for the Kubernetes API..."
        sleep 5
      done

      if kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io apps >/dev/null 2>&1; then
        echo "Flux is already bootstrapped; it manages itself from here."
        exit 0
      fi

      # CRDs first, and established, before what uses them.
      apply_dir() {
        (
          cd "$1"
          shopt -s nullglob
          crds=(CustomResourceDefinition-*.yaml)
          if [ ''${#crds[@]} -gt 0 ]; then
            kubectl apply --server-side --force-conflicts $(printf -- '-f %s ' "''${crds[@]}")
            kubectl wait --for=condition=Established --timeout=120s $(printf -- '-f %s ' "''${crds[@]}")
          fi
          kubectl apply --server-side --force-conflicts -f .
        )
      }

      echo "Installing Flux..."
      kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
      apply_dir ${env}/flux

      echo "Creating the Kustomizations..."
      kubectl apply --server-side --force-conflicts -f ${env}/flux-apps
      ${lib.optionalString k8sVars.layers.longhorn ''
        # Longhorn's Kustomization is suspended (no push reaches storage
        # unattended), but on a fresh cluster nothing has applied it, and
        # apps with volumes wait for it: apply it this once.
        echo "Installing Longhorn for the first time..."
        apply_dir ${env}/longhorn
      ''}
      echo "Done. Watch it converge: kubectl -n flux-system get kustomizations"
    '';
  };

  # `flux get kustomizations`, `flux resume kustomization longhorn`, ...
  cli = pkgs: [ pkgs.fluxcd ];

  # Its metrics (monitoring.nix passes its helpers): the controllers' pods,
  # and its readiness through kube-state-metrics.
  monitoring = { namespace, ... }:
    let
      # Flux's readiness (the FluxNotReady alert): kube-state-metrics reads its
      # Kustomizations and GitRepository, as Flux's monitoring guide does (the
      # controllers themselves don't export it).
      stateMetrics = {
        rbac.extraRules = [{
          apiGroups = [ "kustomize.toolkit.fluxcd.io" "source.toolkit.fluxcd.io" ];
          resources = [ "kustomizations" "gitrepositories" ];
          verbs = [ "list" "watch" ];
        }];
        customResourceState = {
          enabled = true;
          config.spec.resources = map (gvk: {
            groupVersionKind = gvk // { version = "v1"; };
            metricNamePrefix = "gotk";
            metrics = [{
              name = "resource_info";
              help = "The current state of a Flux ${gvk.kind}.";
              each = {
                type = "Info";
                info.labelsFromPath.name = [ "metadata" "name" ];
              };
              labelsFromPath = {
                exported_namespace = [ "metadata" "namespace" ];
                ready = [ "status" "conditions" "[type=Ready]" "status" ];
                suspended = [ "spec" "suspend" ];
              };
            }];
          }) [
            { group = "kustomize.toolkit.fluxcd.io"; kind = "Kustomization"; }
            { group = "source.toolkit.fluxcd.io"; kind = "GitRepository"; }
          ];
        };
      };

      # Flux's controllers have no metrics Service: their pods are scraped.
      fluxControllers = [ "source-controller" "kustomize-controller" ];
      fluxPodMonitor = {
        apiVersion = "monitoring.coreos.com/v1";
        kind = "PodMonitor";
        metadata = { name = "flux"; inherit namespace; };
        spec = {
          namespaceSelector.matchNames = [ "flux-system" ];
          selector.matchExpressions = [{ key = "app"; operator = "In"; values = fluxControllers; }];
          podMetricsEndpoints = [{ port = "http-prom"; interval = "60s"; }];
        };
      };
      fluxScrape = {
        job_name = "flux";
        scrape_interval = "60s";
        kubernetes_sd_configs = [{ role = "pod"; namespaces.names = [ "flux-system" ]; }];
        relabel_configs = [{
          source_labels = [ "__meta_kubernetes_pod_label_app" "__meta_kubernetes_pod_container_port_name" ];
          regex = "(${lib.concatStringsSep "|" fluxControllers});http-prom";
          action = "keep";
        }];
      };
    in {
      objects = [ fluxPodMonitor ];
      scrapeConfigs = [ fluxScrape ];
      kubeStateMetrics = stateMetrics;
    };
  # Where the master puts the SOPS age key for decrypting Secrets
  # (services/core/secrets.nix): the Secret sops-age, this namespace and
  # entry; its kustomize-controller takes the *.agekey entries of the Secret a Kustomization names.
  sopsKey = { namespace = "flux-system"; entry = "age.agekey"; };

  # Nothing besides the files: the Kustomization decrypts them (app.nix,
  # apps with sopsDecrypt).
  secretsFiles = _: { };

  # Its alerts in monitoring-rules.nix start with this.
  alertPrefix = "Flux";
}
