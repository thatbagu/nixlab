# nix run .#new-app -- <name> <image> <port>: scaffold apps/<name>.nix.
# The template and the reserved names are Nix; the script fills them in,
# pins the image digest (crane) and writes the file.
{ pkgs, lib, vars, mkTool }:

let
  # Names nixlab itself uses (rendered directories, namespaces).
  reserved = [ "apps" "argocd" ];

  # @NAME@, @IMAGE@ and @PORT@ are filled in by the script.
  templateText = ''
    # @NAME@: https://@NAME@.<your domain> (LAN, and VPN peers allowed to reach it).
    # All options: system/k8s/lib.nix (nixlab.webApp) and docs/adding-charts.md.
    { nixlab, ... }:

    nixlab.webApp {
      name = "@NAME@";
      image = "@IMAGE@";
      port = @PORT@;

      # Persistent storage (Longhorn, backed up with everything else):
      # storage."/data" = "1Gi";

      # Environment variables:
      # env.TZ = "UTC";

      # Values from a Kubernetes Secret (pushed from SOPS, see docs/secrets.md):
      # secretEnv.API_KEY = { secret = "@NAME@"; key = "api-key"; };

      # Another hostname, or null for no Ingress (cluster-internal only):
      # host = "something.''${nixlab.vars.domain}";
    }
  '';
  template = pkgs.writeText "app-template.nix" templateText;
in
(mkTool {
  name = "new-app";
  runtimeInputs = with pkgs; [ crane git gnused ];
  text = ''
    if [[ $# -ne 3 ]]; then
      echo "Usage: nix run .#new-app -- <name> <image> <port>" >&2
      echo "Example: nix run .#new-app -- uptime-kuma docker.io/louislam/uptime-kuma:1.23.16 3001" >&2
      exit 1
    fi
    name=$1 image=$2 port=$3

    [[ "$name" =~ ^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$ ]] \
      || { echo "Name must be lowercase letters, digits and dashes (it becomes a namespace and hostname)." >&2; exit 1; }
    case "$name" in
      ${lib.concatStringsSep "|" reserved}) echo "\"$name\" is reserved by nixlab, pick another name." >&2; exit 1 ;;
    esac
    [[ "$port" =~ ^[0-9]+$ ]] || { echo "Port must be a number." >&2; exit 1; }
    file="apps/$name.nix"
    [[ -e "$file" || -e "apps/$name" ]] && { echo "$file already exists." >&2; exit 1; }

    # Pin the image to its current digest, so the app only changes when you
    # change this file.
    if [[ "$image" != *@sha256:* ]]; then
      if digest=$(crane digest "$image" 2>/dev/null); then
        image="$image@$digest"
        echo "Pinned to $digest"
      else
        echo "Couldn't resolve a digest for $image (offline, private or misspelled?); using the tag as is."
      fi
    fi

    sed -e "s|@NAME@|$name|g" -e "s|@IMAGE@|$image|g" -e "s|@PORT@|$port|g" ${template} > "$file"
    # Flakes only see files git knows about, so register it right away.
    git add --intent-to-add "$file" 2>/dev/null || true

    cat <<EOF
    Created $file.

    Next:
      1. Adjust it (storage, env, ...).
      2. Preview: nix run .#render   (output in ./result/$name)
      3. git add $file && git commit -m "add $name" && git push
         CI renders it, Argo CD deploys it within a few minutes.
    EOF
  '';
}) // {
  # For the tests: the scaffold must render (tests/default.nix).
  inherit templateText;
}
