# Runs inside the VM tests that have no git server for Argo CD: decrypts and
# applies a render's Secrets directory the way Argo CD's repo server does
# (Kustomize with KSOPS), with the age key the master placed in the cluster
# (Secret argocd/sops-age), so that key is checked too.
# Usage: apply-secrets <rendered dir of nixlab-secrets>
{ pkgs }:

pkgs.writeShellApplication {
  name = "apply-secrets";
  runtimeInputs = with pkgs; [ kubectl kustomize kustomize-sops coreutils ];
  text = ''
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    key=$(mktemp)
    kubectl -n argocd get secret sops-age -o jsonpath='{.data.keys\.txt}' | base64 -d > "$key"
    # A plain copy, as Argo CD's git checkout is: the render's files are
    # symlinks into the store, and kustomize doesn't follow a symlinked
    # kustomization.yaml.
    dir=$(mktemp -d); trap 'rm -rf "$key" "$dir"' EXIT
    cp -rL "$1"/. "$dir"/
    SOPS_AGE_KEY_FILE=$key kustomize build --enable-alpha-plugins --enable-exec "$dir" \
      | kubectl apply --server-side --field-manager=argocd-test -f -
  '';
}
