# nix run .#new-app -- <name> <image> <port>: scaffold apps/<name>.nix.

if [[ $# -ne 3 ]]; then
  cat >&2 <<EOF
Usage: nix run .#new-app -- <name> <image> <port>
Example: nix run .#new-app -- uptime-kuma docker.io/louislam/uptime-kuma:1.23.16 3001
EOF
  exit 1
fi
name=$1 image=$2 port=$3

[[ -d apps && -f flake.nix ]] || { echo "Run this from the root of your nixlab repository." >&2; exit 1; }
[[ "$name" =~ ^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$ ]] \
  || { echo "Name must be lowercase letters, digits and dashes (it becomes a namespace and hostname)." >&2; exit 1; }
[[ "$port" =~ ^[0-9]+$ ]] || { echo "Port must be a number." >&2; exit 1; }
case "$name" in
  apps|argocd) echo "\"$name\" is reserved by nixlab, pick another name." >&2; exit 1 ;;
esac
file="apps/$name.nix"
[[ -e "$file" || -e "apps/$name" ]] && { echo "$file already exists." >&2; exit 1; }

# Pin the image to its current digest, so the app only changes when you
# change this file.
if [[ "$image" != *@sha256:* ]]; then
  if digest=$(crane digest "$image" 2>/dev/null); then
    image="$image@$digest"
    echo "Pinned to $digest"
  else
    echo "Couldn't resolve a digest for $image (private or misspelled?); using the tag as is."
  fi
fi

cat > "$file" <<EOF
# $name: https://$name.<your domain> (LAN, and VPN peers allowed to reach it).
# All options: system/k8s/lib.nix (nixlab.webApp) and
# docs/adding-charts.md.
{ nixlab, ... }:

nixlab.webApp {
  name = "$name";
  image = "$image";
  port = $port;

  # Persistent storage (Longhorn, backed up with everything else):
  # storage."/data" = "1Gi";

  # Environment variables:
  # env.TZ = "UTC";

  # Values from a Kubernetes Secret (pushed from SOPS, see docs/secrets.md):
  # secretEnv.API_KEY = { secret = "$name"; key = "api-key"; };

  # Another hostname, or null for no Ingress (cluster-internal only):
  # host = "something.\${nixlab.vars.domain}";
}
EOF

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
