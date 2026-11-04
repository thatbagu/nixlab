# nix run .#update: update everything that's pinned, the way the weekly CI job
# (.github/workflows/update.yml) does:
#   1. flake inputs: nixpkgs (NixOS, k3s, kernel), nixhelm (Helm charts), ...
#   2. image digests pinned in system/ and apps/, at their current tags (fixes
#      within a version; tag/version bumps stay your decision)
#   3. the VM tests' preloaded images (tests/vm/images.json), from the images
#      the new render uses
# It prints a summary, and lists Helm charts whose major version changed: the
# CI job merges by itself only when there are none.
{ pkgs, lib, vars, mkTool }:

let
  # The render with every optional app, to see all charts and images.
  renderAttr = ".#checks.x86_64-linux.render-monitoring";
  # The VM tests' own fixtures (not part of the render).
  testImages = {
    whoami = "docker.io/traefik/whoami:v1.11.0";
    http-https-echo = "docker.io/mendhak/http-https-echo:43";
  };
  # Which rendered app's images each VM test preloads.
  vmTestApps = [ "argocd" "monitoring" ];
in
mkTool {
  name = "update";
  runtimeInputs = with pkgs; [ nix git crane jq gnugrep gnused coreutils findutils nix-prefetch-docker ];
  text = ''
    summary=$(mktemp)
    note() { echo "$*" | tee -a "$summary"; }

    # Chart name -> version, from the rendered helm.sh/chart labels.
    charts() { grep -RhoE 'helm.sh/chart: "?[A-Za-z0-9-]+-v?[0-9][^" ]*' "$1" | sed -E 's/.*chart: "?//' | sort -u; }

    echo "==> Rendering the current manifests"
    old=$(nix build --no-link --print-out-paths ${renderAttr})

    echo "==> Updating flake inputs"
    nix flake update 2>&1 | grep -E "Updated input|•" | tee -a "$summary" || true

    echo "==> Refreshing pinned image digests"
    while IFS= read -r ref; do
      image=''${ref%@*} pinned=''${ref#*@}
      if current=$(crane digest "$image" 2>/dev/null) && [[ "$current" != "$pinned" ]]; then
        grep -rlF "$ref" system apps | xargs sed -i "s|$ref|$image@$current|g"
        note "image $image: new digest"
      fi
    done < <(grep -rhoE '[a-z0-9.-]+\.[a-z]+/[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}' system apps | sort -u)

    echo "==> Rendering with the updates"
    git add -A
    new=$(nix build --no-link --print-out-paths ${renderAttr})

    majors=$(join -j1 \
      <(charts "$old" | sed -E 's/-v?([0-9]+)\..*/ \1/' | sort -u) \
      <(charts "$new" | sed -E 's/-v?([0-9]+)\..*/ \1/' | sort -u) \
      | awk '$2 != $3 {print $1 " " $2 " -> " $3}')
    comm -13 <(charts "$old" | sort) <(charts "$new" | sort) | sed 's/^/chart /' | tee -a "$summary"

    echo "==> Updating the VM tests' images"
    images=tests/vm/images.json
    wanted=$( {
      for app in ${lib.concatStringsSep " " vmTestApps}; do
        # Charts' own test pods (helm test) never run in the VM tests.
        grep -RhoE --exclude='Pod-*-test*.yaml' '(image: |prometheus-config-reloader=)"?[a-z0-9.-]+\.[a-z]+/[^" ]+' "$new/$app" | sed -E 's/^(image: |prometheus-config-reloader=)"?//'
      done
      printf '%s\n' ${lib.escapeShellArgs (lib.attrValues testImages)}
    } | sed 's/@sha256:.*//' | sort -u)
    next=$(mktemp); echo '{}' > "$next"
    for ref in $wanted; do
      name=''${ref%:*} tag=''${ref##*:} key=''${name##*/}
      kept=$(jq -c --arg n "$name" --arg t "$tag" 'to_entries[] | select(.value.imageName == $n and .value.finalImageTag == $t) | .value' "$images")
      if [[ -z "$kept" ]]; then
        kept=$(nix-prefetch-docker --image-name "$name" --image-tag "$tag" --os linux --arch amd64 --json --quiet \
          | jq -c '{imageName, imageDigest, hash: (.hash // .sha256), finalImageTag}')
        note "VM test image $name:$tag"
      fi
      jq --arg k "$key" --argjson v "$kept" '.[$k] = $v' "$next" > "$next.tmp" && mv "$next.tmp" "$next"
    done
    jq -S . "$next" > "$images"

    git add -A
    echo
    if git diff --cached --quiet; then
      echo "Everything is up to date."
      changed=false
    else
      changed=true
      echo "Changed:"; sed 's/^/  /' "$summary"
    fi
    if [[ -n "$majors" ]]; then
      echo; echo "Major version changes (review before merging):"; while IFS= read -r line; do echo "  $line"; done <<<"$majors"
    fi
    if [[ -n "''${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "changed=$changed"
        echo "majors<<EOF"; echo "$majors"; echo "EOF"
        echo "summary<<EOF"; cat "$summary"; echo "EOF"
      } >> "$GITHUB_OUTPUT"
    fi
  '';
}
