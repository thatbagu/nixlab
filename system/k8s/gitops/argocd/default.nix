# Argo CD as nixlab's GitOps engine: the interface is in ../default.nix.
{ lib }:

{
  name = "Argo CD";
  # The controller itself, as a nixidy app (self-gated on vars.argocd).
  module = ./app.nix;

  # Never let Argo CD delete storage, CRDs or namespaces, whether by pruning
  # or by deleting an Application. Appends to existing sync-options (e.g.
  # ServerSideApply=true on large CRDs).
  protect = obj:
    let
      key = "argocd.argoproj.io/sync-options";
      existing = obj.metadata.annotations.${key} or "";
      options = lib.filter (o: o != "") (lib.splitString "," existing)
        ++ [ "Prune=false" "Delete=false" ];
    in { ${key} = lib.concatStringsSep "," (lib.unique options); };

  # The master's one-time install on a fresh cluster (system/k8s/default.nix).
  bootstrapOption = "bootstrapArgo";
  bootstrap = { pkgs, nixidyEnv, k8sVars }: {
    name = "argocd-bootstrap";
    description = "Install Argo CD on a fresh cluster";
    path = [ pkgs.kubectl pkgs.jq ];
    script = ''
      set -o pipefail

      until kubectl get --raw /readyz >/dev/null 2>&1; do
        echo "Waiting for the Kubernetes API..."
        sleep 5
      done

      if kubectl -n argocd get applications.argoproj.io apps >/dev/null 2>&1; then
        # Argo CD manages everything else from git, but nothing manages the
        # parent Application itself: keep it as this nixlab version renders
        # it (e.g. its sync retries).
        kubectl apply -f ${nixidyEnv.bootstrapPackage}/Application-apps.yaml
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
      ${lib.optionalString k8sVars.layers.longhorn ''
        # Longhorn is manual-sync (no push reaches storage unattended), but
        # on a fresh cluster nothing has synced it, and the apps after it
        # (sync waves) wait for it: sync it this once.
        # Its Application comes from the render (the app-of-apps adopts it),
        # so this doesn't wait for Argo CD to read git.
        echo "Syncing Longhorn for the first time..."
        kubectl apply -f ${nixidyEnv.environmentPackage}/apps/Application-longhorn.yaml
        # A sync started before Argo CD made its "default" project fails
        # ("app project default not found") and isn't retried.
        for _ in $(seq 60); do
          kubectl -n argocd get appprojects.argoproj.io default >/dev/null 2>&1 && break
          sleep 5
        done
        # An operation doesn't inherit the app's sync options or retry:
        # without them the namespace isn't created ("namespaces
        # \"longhorn-system\" not found") and a failure is final.
        kubectl -n argocd get applications.argoproj.io longhorn -o json \
          | jq -c '{operation: {initiatedBy: {username: "nixlab-bootstrap"},
              sync: {revision: "${k8sVars.renderedBranch}", syncOptions: (.spec.syncPolicy.syncOptions // [])},
              retry: (.spec.syncPolicy.retry // {})}}' \
          | kubectl -n argocd patch applications.argoproj.io longhorn --type merge --patch-file /dev/stdin
      ''}
      echo "Done. Watch it converge: kubectl -n argocd get applications"
    '';
  };

  cli = _pkgs: [ ];

  # Its metrics (monitoring.nix passes its helpers).
  monitoring = { serviceMonitor, scrapeService, ... }: {
    objects = [
      (serviceMonitor {
        name = "argocd";
        ns = "argocd";
        selector."app.kubernetes.io/name" = "argocd-metrics";
        port = "http-metrics";
      })
    ];
    scrapeConfigs = [
      (scrapeService { job = "argocd"; ns = "argocd"; service = "argocd-application-controller-metrics"; port = "http-metrics"; })
    ];
    kubeStateMetrics = { };
  };
  # Its alerts in monitoring-rules.nix start with this.
  alertPrefix = "Argo";
}
