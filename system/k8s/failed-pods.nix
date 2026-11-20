# nixlab-gc-failed-pods, hourly on masters: after a node restarts, the pods
# that were running on it stay listed as Failed (Error, NodeShutdown) next to
# their replacements, until Kubernetes' garbage collector kicks in at 12,500
# finished pods. This deletes failed pods that a ReplicaSet, StatefulSet or
# DaemonSet has replaced. Job pods stay: they're what you'd look at.
{ pkgs, kubectl ? pkgs.kubectl }:

pkgs.writeShellApplication {
  name = "nixlab-gc-failed-pods";
  runtimeInputs = [ kubectl pkgs.jq ];
  text = ''
    export KUBECONFIG=''${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
    kubectl get pods -A --field-selector=status.phase=Failed -o json | jq -r '
      .items[]
      | select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet" or .kind == "StatefulSet" or .kind == "DaemonSet"))
      | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns pod; do
        kubectl -n "$ns" delete pod "$pod" --wait=false >/dev/null && echo "deleted $ns/$pod"
      done
  '';
}
