# nix run .#move-app -- <app> native|kubernetes [--node <hostname>] [--dry-run]:
# move an app (nixlab.app) between Kubernetes and running natively on a node,
# with its data. The data is copied before the switch, so the app starts with
# it either way:
# - to native: a helper pod mounts each of the app's volumes and streams it
#   into the node's directory (under /persist on nodes whose root is wiped at
#   boot, where the deploy's mount reads it from; the app keeps running until
#   the deploy; with GitOps its old volume stays, as nixlab never prunes
#   volumes, and without it k3s removes it with the app);
# - to Kubernetes: the native service stops, each volume is created, and a
#   helper pod streams the node's directory into it.
# Then it sets `runtime` (and `node`) in the app's file: commit and push.
{ pkgs, lib, vars, mkTool, appsData ? null, ... }:

let
  addressOf = n: n.address or "${n.hostname}.local";
  masters = lib.filter (n: n.master or false) (lib.attrValues vars.nodes);
  k8sVars = import ../system/k8s/vars.nix vars;
  # nixlab's pinned alpine (services/vpn/wireguard.nix): tar in the helper pod.
  helperImage = "docker.io/library/alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f";
in
mkTool {
  name = "move-app";
  runtimeInputs = with pkgs; [ jq openssh gnused gnugrep coreutils ];
  text = ''
    usage() { echo "usage: nix run .#move-app -- <app> native|kubernetes [--node <hostname>] [--dry-run]" >&2; exit 2; }
    app=''${1:-}; to=''${2:-}; [[ -n "$app" && ( "$to" == native || "$to" == kubernetes ) ]] || usage
    shift 2
    node="" dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in --node) node=''${2:?}; shift ;; --dry-run) dry=1 ;; *) usage ;; esac
      shift
    done
    SSH=''${NIXLAB_SSH:-ssh}
    helper=''${NIXLAB_HELPER_IMAGE:-${helperImage}}
    user=${lib.escapeShellArg vars.username}
    master=${lib.escapeShellArg (if masters == [ ] then "" else addressOf (lib.head masters))}
    on() { $SSH -o BatchMode=yes "$user@$1" "$2"; }
    k() { on "$master" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"; }
    addr() { jq -r --arg n "$1" '.[$n] // $n' <<<${lib.escapeShellArg (builtins.toJSON (lib.listToAttrs (map (n: lib.nameValuePair n.hostname (addressOf n)) (lib.attrValues vars.nodes))))}; }
    # The helper pod copying the data (a new name each run: an earlier one may
    # still be terminating).
    pod="move-$app-$(date +%s)"
    run() { if [[ $dry == 1 ]]; then echo "  would: $*"; else eval "$*"; fi; }

    # What the render knows about the app (baked in: nix run builds this tool
    # from your current checkout). NIXLAB_APPS_DATA overrides it (tests).
    data=''${NIXLAB_APPS_DATA:-${if appsData == null then "" else pkgs.writeText "nixlab-apps.json" (builtins.toJSON appsData)}}
    [[ -n "$data" ]] || { echo "move-app needs your lab's render (run it from your homelab repo)." >&2; exit 1; }
    info=$(jq --arg a "$app" '{ native: .native[$a], k8s: .kubernetes[$a] }' "$data")
    file=$(grep -rlE "name = \"$app\";" apps/ 2>/dev/null | head -1)
    [[ -n "$file" ]] || { echo "No app file in apps/ names $app." >&2; exit 1; }
    from=kubernetes; jq -e '.native != null' <<<"$info" >/dev/null && from=native
    [[ "$from" != "$to" ]] || { echo "$app already runs on $to." >&2; exit 1; }
    if jq -e '.native.stateOn == "nas"' <<<"$info" >/dev/null; then
      echo "$app keeps its data on the NAS (stateOn = \"nas\"): to move it to another node, change node in its file. Moving it to Kubernetes needs stateOn = \"node\" first." >&2
      exit 1
    fi

    # Its data: (mount path in the container, claim) pairs on Kubernetes; the
    # node's directory per path natively (Podman apps: /var/lib/nixlab/<app>/...).
    nativeDir() { local p=''${1#/}; if jq -e '.native == null or (.native.module | not)' <<<"$info" >/dev/null; then echo "/var/lib/nixlab/$app/''${p//\//-}"; else echo "$1"; fi; }

    if [[ "$to" == native ]]; then
      [[ -n "$node" ]] || { echo "Moving to native needs --node <hostname>." >&2; exit 1; }
      jq -e '.k8s != null' <<<"$info" >/dev/null || { echo "$app has no volumes on Kubernetes: only its file changes." >&2; }
      ns=$(jq -r '.k8s.namespace // empty' <<<"$info")
      mapfile -t pairs < <(jq -r '.k8s.volumes[]? | "\(.path) \(.claim)"' <<<"$info")
      echo "Moving $app ($ns) to native on $node: ''${#pairs[@]} volume(s)."
      podNode=$(k "-n $ns get pods -l app.kubernetes.io/name=$app -o jsonpath='{.items[0].spec.nodeName}'" 2>/dev/null || true)
      for pair in "''${pairs[@]}"; do
        path=''${pair% *} claim=''${pair#* } dir=$(nativeDir "$path")
        echo "  $claim ($path) -> $node:$dir"
        run "k \"-n $ns run $pod --image=$helper --restart=Never --overrides='{\\\"spec\\\":{\\\"nodeName\\\":\\\"''${podNode}\\\",\\\"volumes\\\":[{\\\"name\\\":\\\"d\\\",\\\"persistentVolumeClaim\\\":{\\\"claimName\\\":\\\"$claim\\\",\\\"readOnly\\\":true}}],\\\"containers\\\":[{\\\"name\\\":\\\"m\\\",\\\"image\\\":\\\"$helper\\\",\\\"command\\\":[\\\"sleep\\\",\\\"3600\\\"],\\\"volumeMounts\\\":[{\\\"name\\\":\\\"d\\\",\\\"mountPath\\\":\\\"/d\\\"}]}]}}'\" >/dev/null"
        run "k \"-n $ns wait --for=condition=Ready pod/$pod --timeout=120s\" >/dev/null"
        run "k \"-n $ns exec $pod -- tar -C /d -cf - .\" | on \"$(addr "$node")\" \"d=$dir; [ -d /persist ] && d=/persist$dir; sudo mkdir -p \\\$d && sudo tar -C \\\$d -xpf -\""
        run "k \"-n $ns delete pod $pod --wait=false\" >/dev/null"
      done
    else
      ns=$(jq -r '.native.namespace' <<<"$info"); node=$(jq -r '.native.node' <<<"$info")
      nodeAddr=$(addr "$node")
      unit=$(jq -r 'if .native.module then .native.name else "podman-\(.native.name)" end' <<<"$info")
      echo "Moving $app ($ns) from $node to Kubernetes."
      run "on \"$nodeAddr\" \"sudo systemctl stop $unit\""
      for path in $(jq -r '.native.state[]' <<<"$info"); do
        p=''${path#/}; claim="$app-''${p//\//-}" dir=$(nativeDir "$path")
        echo "  $node:$dir -> $claim ($path)"
        run "k \"-n $ns create namespace $ns\" >/dev/null 2>&1 || true"
        size=$(jq -r --arg p "$path" '.native.stateSizes[$p] // "5Gi"' <<<"$info")
        run "k \"-n $ns get pvc $claim\" >/dev/null 2>&1 || printf '%s' '{\"apiVersion\":\"v1\",\"kind\":\"PersistentVolumeClaim\",\"metadata\":{\"name\":\"$claim\",\"namespace\":\"$ns\"},\"spec\":{\"accessModes\":[\"ReadWriteOnce\"],\"storageClassName\":\"${k8sVars.storageClass}\",\"resources\":{\"requests\":{\"storage\":\"$size\"}}}}' | on \"$master\" \"KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl apply -f -\" >/dev/null"
        run "k \"-n $ns run $pod --image=$helper --restart=Never --overrides='{\\\"spec\\\":{\\\"volumes\\\":[{\\\"name\\\":\\\"d\\\",\\\"persistentVolumeClaim\\\":{\\\"claimName\\\":\\\"$claim\\\"}}],\\\"containers\\\":[{\\\"name\\\":\\\"m\\\",\\\"image\\\":\\\"$helper\\\",\\\"command\\\":[\\\"sleep\\\",\\\"3600\\\"],\\\"stdin\\\":true,\\\"volumeMounts\\\":[{\\\"name\\\":\\\"d\\\",\\\"mountPath\\\":\\\"/d\\\"}]}]}}'\" >/dev/null"
        run "k \"-n $ns wait --for=condition=Ready pod/$pod --timeout=300s\" >/dev/null"
        run "on \"$nodeAddr\" \"sudo tar -C $dir -cf - .\" | k \"-n $ns exec -i $pod -- tar -C /d -xpf -\""
        run "k \"-n $ns delete pod $pod --wait=false\" >/dev/null"
      done
    fi

    # The switch, in the app's file.
    if grep -qE 'runtime = "(native|kubernetes)";' "$file"; then
      run "sed -i -E 's/runtime = \"(native|kubernetes)\";/runtime = \"$to\";/' $file"
    else
      run "sed -i -E '0,/name = \"$app\";/s//name = \"$app\"; runtime = \"$to\";/' $file"
    fi
    if [[ "$to" == native ]]; then
      if grep -qE 'node = "[^"]*";' "$file"; then run "sed -i -E 's/node = \"[^\"]*\";/node = \"$node\";/' $file"
      else run "sed -i -E '0,/runtime = \"native\";/s//runtime = \"native\"; node = \"$node\";/' $file"; fi
    fi
    echo "Done: $app's data is in place for $to, and $file says runtime = \"$to\"."
    echo "Commit and push it; the app starts there with its data.${if k8sVars.layers.gitops then "" else " (Without GitOps: colmena apply.)"}"
  '';
}
