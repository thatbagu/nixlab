# nix run .#update: update everything that's pinned, the way the weekly CI job
# (.github/workflows/update.yml) does:
#   1. flake inputs: nixpkgs (NixOS, k3s, kernel), nixhelm (Helm charts), ...
#   2. image digests pinned in system/ and apps/, at their current tags (fixes
#      within a version; tag/version bumps stay your decision)
#   3. the VM tests' preloaded images (tests/vm/images.json), from the images
#      the new render uses
# It prints a summary, and lists Helm charts whose major version changed: the
# CI job merges by itself only when there are none.
{ pkgs, lib, vars, mkTool, library, ... }:

let
  # Renders that together contain every chart. In the nixlab repo: both
  # monitoring flavors (tests/); in a homelab repo: its own render.
  renders = if library then [ "render-monitoring" "render-monitoring-full" ] else [ "manifests" ];
  # Where pinned images live: the platform, or your apps.
  digestDirs = if library then "system" else "apps";
  # Each VM test's preloaded images: those of a rendered app, plus the test's
  # own fixtures (not part of the render).
  vmTests = {
    vm-cluster = { render = "render-default"; apps = [ "argocd" ]; extra = [ "docker.io/traefik/whoami:v1.11.0" ]; };
    vm-monitoring = { render = "render-monitoring"; apps = [ "monitoring" ]; extra = [ "docker.io/mendhak/http-https-echo:43" ]; };
    vm-monitoring-full = { render = "render-monitoring-full"; apps = [ "monitoring" ]; extra = [ "docker.io/mendhak/http-https-echo:43" ]; };
    vm-minimal = { render = "render-minimal"; apps = [ ]; extra = [ "docker.io/traefik/whoami:v1.11.0" ]; };
    vm-sso = { render = "render-sso-vm"; apps = [ "wireguard" "cert-manager" "cert-manager-issuers" ]; extra = [ ]; };
  };
  build = check: "nix build --no-link --print-out-paths .#checks.x86_64-linux.${check}";
  # The nixlab repo only: regenerate the VM tests' preloaded images.
  vmImages = ''
    echo "==> Updating the VM tests' images"
    images=tests/vm/images.json
    next=$(mktemp); echo '{}' > "$next"
    ${lib.concatStrings (lib.mapAttrsToList (test: t: ''
      env=$(${build t.render})
      wanted=$( {
        # Charts' own test pods (helm test) never run in the VM tests.
        ${lib.concatMapStrings (app: ''
          grep -RhoE --exclude='Pod-*-test*.yaml' '(image: |prometheus-config-reloader=)"?[a-z0-9.-]+\.[a-z]+/[^" ]+' "$env/${app}" \
            | sed -E 's/^(image: |prometheus-config-reloader=)"?//'
        '') t.apps}
        ${lib.optionalString (t.extra != [ ]) "printf '%s\\n' ${lib.escapeShellArgs t.extra}"}
      } | sort -u)
      for ref in $wanted; do
        # name[:tag][@sha256:...]; digest-only images get the tag "latest"
        # (the VM tests strip digests: preloaded images match by tag).
        base=''${ref%@*} digest=""
        [[ "$ref" == *@sha256:* ]] && digest=''${ref#*@}
        if [[ "''${base##*/}" == *:* ]]; then name=''${base%:*} tag=''${base##*:}; else name=$base tag=latest; fi
        key=''${name##*/}
        kept=$(jq -c --arg n "$name" --arg t "$tag" --arg d "$digest" \
          '[.[][] | select(.imageName == $n and .finalImageTag == $t and ($d == "" or .imageDigest == $d))] | first // empty' "$images")
        if [[ -z "$kept" ]]; then
          if [[ -n "$digest" ]]; then by=(--image-digest "$digest" --final-image-tag "$tag"); else by=(--image-tag "$tag"); fi
          kept=$(nix-prefetch-docker --image-name "$name" "''${by[@]}" --os linux --arch amd64 --json --quiet \
            | jq -c '{imageName, imageDigest, hash: (.hash // .sha256), finalImageTag}')
          note "VM test image $name:$tag"
        fi
        jq --arg g ${test} --arg k "$key" --argjson v "$kept" '.[$g][$k] = $v' "$next" > "$next.tmp" && mv "$next.tmp" "$next"
      done
    '') vmTests)}
    jq -S . "$next" > "$images"
  '';
in
mkTool {
  name = "update";
  runtimeInputs = with pkgs; [ nix git crane jq gnugrep gnused coreutils findutils nix-prefetch-docker ];
  text = ''
    summary=$(mktemp)
    note() { echo "$*" | tee -a "$summary"; }

    # Chart name -> version, from the rendered helm.sh/chart labels.
    charts() { grep -RhoE 'helm.sh/chart: "?[A-Za-z0-9-]+-v?[0-9][^" ]*' "$@" | sed -E 's/.*chart: "?//' | sort -u; }

    echo "==> Rendering the current manifests"
    mapfile -t old < <(${lib.concatMapStringsSep "; " build renders})

    echo "==> Updating flake inputs"
    nix flake update 2>&1 | grep -E "Updated input|•" | tee -a "$summary" || true

    echo "==> Refreshing pinned image digests"
    while IFS= read -r ref; do
      image=''${ref%@*} pinned=''${ref#*@}
      if current=$(crane digest "$image" 2>/dev/null) && [[ "$current" != "$pinned" ]]; then
        grep -rlF "$ref" ${digestDirs} | xargs sed -i "s|$ref|$image@$current|g"
        note "image $image: new digest"
      fi
    done < <( [[ -d ${digestDirs} ]] && grep -rhoE '[a-z0-9.-]+\.[a-z]+/[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}' ${digestDirs} | sort -u)

    echo "==> Rendering with the updates"
    git add -A
    mapfile -t new < <(${lib.concatMapStringsSep "; " build renders})

    majors=$(join -j1 \
      <(charts "''${old[@]}" | sed -E 's/-v?([0-9]+)\..*/ \1/' | sort -u) \
      <(charts "''${new[@]}" | sed -E 's/-v?([0-9]+)\..*/ \1/' | sort -u) \
      | awk '$2 != $3 {print $1 " " $2 " -> " $3}')
    comm -13 <(charts "''${old[@]}" | sort) <(charts "''${new[@]}" | sort) | sed 's/^/chart /' | tee -a "$summary"

    ${lib.optionalString library vmImages}

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
