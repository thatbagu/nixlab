# nixlab-longhorn-reset-node <node> [--yes], on masters: after a node was
# reinstalled, Longhorn still expects its old disk ("record diskUUID doesn't
# match the one on the disk") and puts no replicas there. This forgets the old
# disk and its replicas (their data went with it), Longhorn adds a fresh
# default disk, and degraded volumes rebuild onto it. It refuses while any
# volume would lose its last healthy replica. `nix run .#reinstall` runs it.
{ pkgs }:

pkgs.writeShellApplication {
  name = "nixlab-longhorn-reset-node";
  runtimeInputs = with pkgs; [ kubectl jq coreutils ];
  text = ''
    export KUBECONFIG=''${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
    node=''${1:?usage: nixlab-longhorn-reset-node <node> [--yes]}
    yes=0; [[ ''${2:-} == --yes ]] && yes=1
    ns=longhorn-system
    k() { kubectl -n "$ns" "$@"; }

    k get nodes.longhorn.io "$node" >/dev/null 2>&1 || { echo "Longhorn doesn't know a node \"$node\"." >&2; exit 1; }

    # Disks whose record doesn't match what's on the disk now.
    stale=$(k get nodes.longhorn.io "$node" -o json | jq -r '
      .status.diskStatus // {} | to_entries[]
      | select(any(.value.conditions[]?; .type == "Ready" and .status == "False" and (.message | test("diskUUID doesn.t match"))))
      | .key')
    if [[ -z $stale ]]; then
      echo "$node: Longhorn's disk records match, nothing to do."
      exit 0
    fi
    echo "$node: stale disk record(s): $stale"

    # Every volume with a replica on the node needs a healthy one elsewhere.
    replicas=$(k get replicas.longhorn.io -o json)
    unsafe=$(jq -r --arg n "$node" '
      [.items[] | {v: .spec.volumeName, node: .spec.nodeID, ok: ((.spec.failedAt // "") == "")}]
      | group_by(.v)[]
      | select(any(.node == $n) and (map(select(.node != $n and .ok)) | length) == 0)
      | .[0].v' <<<"$replicas")
    if [[ -n $unsafe ]]; then
      echo "These volumes have no healthy replica outside $node, so their data would be gone:" >&2
      echo "$unsafe" >&2
      echo "Restore them from a backup instead (docs: Backups & Restore)." >&2
      exit 1
    fi
    mine=$(jq -r --arg n "$node" '.items[] | select(.spec.nodeID == $n) | .metadata.name' <<<"$replicas")

    if [[ $yes != 1 ]]; then
      echo "Forget $(wc -w <<<"$mine") replica(s) and the stale disk record(s) on $node? Their data was on the old disk."
      read -r -p "Type the node's name to continue: " answer
      [[ $answer == "$node" ]] || { echo "Cancelled."; exit 1; }
    fi

    # shellcheck disable=SC2086
    [[ -z $mine ]] || k delete replicas.longhorn.io $mine --wait=true --timeout=120s >/dev/null
    for d in $stale; do
      k patch nodes.longhorn.io "$node" --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/disks/$d/allowScheduling\",\"value\":false}]" >/dev/null
      k patch nodes.longhorn.io "$node" --type json -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$d\"}]" >/dev/null
    done
    echo "Forgot them; waiting for Longhorn's fresh default disk..."

    for _ in $(seq 60); do
      if k get nodes.longhorn.io "$node" -o json | jq -e '
          [.status.diskStatus // {} | to_entries[] | select(any(.value.conditions[]?; .type == "Ready" and .status == "True"))] | length > 0' >/dev/null; then
        echo "$node: a new disk is ready; degraded volumes rebuild onto it."
        exit 0
      fi
      sleep 5
    done
    echo "$node: no ready disk after 5 minutes. Check: kubectl -n $ns get nodes.longhorn.io $node -o yaml" >&2
    exit 1
  '';
}
