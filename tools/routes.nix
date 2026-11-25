# nix run .#routes [--json]: every app reachable over HTTPS, from your
# repository's render: host, app, where it runs (Kubernetes or a node), its
# volumes and whether they're backed up. Offline: it reads no cluster.
{ pkgs, lib, mkTool, appsData ? null, ... }:

mkTool {
  name = "routes";
  runtimeInputs = with pkgs; [ jq util-linux ];
  text = ''
    data=''${NIXLAB_APPS_DATA:-${if appsData == null then "" else pkgs.writeText "nixlab-apps.json" (builtins.toJSON appsData)}}
    [[ -n "$data" ]] || { echo "routes needs your lab's render (run it from your homelab repo)." >&2; exit 1; }
    if [[ "''${1:-}" == --json ]]; then jq '.routes' "$data"; exit; fi
    {
      echo "HOST	APP	RUNS ON	DATA"
      jq -r '.routes | sort_by(.hosts[0] // "") | .[] |
        (.hosts | join(",")) + "\t" + .app + "\t" +
        (if .runtime == "native" then "node " + .node else "kubernetes" end) + "\t" +
        (if (.volumes | length) == 0 then "-"
         else "\(.volumes | length) volume(s), " + (if .backedUp then "backed up" else "NOT backed up" end) end)' "$data"
    } | column -t -s $'\t'
  '';
}
