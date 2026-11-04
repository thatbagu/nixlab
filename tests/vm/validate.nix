# Runs inside the VM tests: every rendered object must be accepted by the API
# server (server-side dry run; CRDs and namespaces are created for real first).
# Usage: validate <rendered env dir>
{ pkgs }:

pkgs.writeShellApplication {
  name = "validate";
  runtimeInputs = with pkgs; [ kubectl gawk findutils gnugrep ];
  text = ''
    ENV=$1
    mapfile -t crds < <(find -L "$ENV" -name 'CustomResourceDefinition-*.yaml' | sort)
    for f in "''${crds[@]}"; do kubectl apply --server-side --force-conflicts -f "$f" >/dev/null; done
    kubectl wait --for=condition=Established --timeout=120s "''${crds[@]/#/-f}" >/dev/null
    mapfile -t namespaces < <(grep -RhoE '^  namespace: [a-z0-9-]+' "$ENV" | awk '{print $2}' | sort -u)
    for ns in "''${namespaces[@]}"; do
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    done
    errors=0 count=0
    while IFS= read -r f; do
      count=$((count + 1))
      if ! out=$(kubectl apply --dry-run=server --server-side --force-conflicts -f "$f" 2>&1); then
        # The platform's admission webhooks aren't running here.
        if grep -qE 'failed calling webhook|no endpoints available for service' <<<"$out"; then continue; fi
        echo "''${f#"$ENV"/}: $out"
        errors=$((errors + 1))
      fi
    done < <(find -L "$ENV" -name '*.yaml' ! -name 'CustomResourceDefinition-*' | sort)
    echo "''${#crds[@]} CRDs, $count objects, $errors rejected"
    [[ $errors -eq 0 ]]
  '';
}
