# nix run .#update: keeps everything that's pinned up to date, one update at
# a time. The weekly CI job (.github/workflows/update.yml) tests each one on
# its own, merges the ones that pass and opens a pull request for the rest.
#
# What gets updated, each its own unit:
#   input:<name>        a flake input (nixpkgs: NixOS, k3s, kernel; nixlab in
#                       your homelab repo; ...)
#   chart:<repo>/<c>    a Helm chart, to its newest release in the same major
#                       version (charts/<repo>/<chart>/default.nix)
#   chart-major:...     a Helm chart's new major version (never merged by
#                       itself: read its release notes)
#   image:<ref>         a pinned image's digest at its current tag (security
#                       fixes within a version)
#   image-tag:<ref>     a pinned image's newer tag (never merged by itself)
#
#   nix run .#update              everything but the majors and new tags
#   nix run .#update -- list      the units with an update (JSON)
#   nix run .#update -- apply ID  one unit; in CI it also says which tests
#                                 to run for it
{ pkgs, lib, vars, mkTool, library, ... }:

let
  # Where pinned images and charts live: the platform's, or your repo's.
  digestDirs = if library then "system" else "apps";
  chartsDir = if library then "system/k8s/charts" else "charts";
  # Each VM test's preloaded images: those of a rendered app, plus the test's
  # own fixtures (not part of the render). A chart or image update runs the
  # VM tests whose apps it changes.
  vmTests = {
    vm-cluster = { render = "render-default"; apps = [ "argocd" "nixlab-secrets" ]; extra = [ "docker.io/traefik/whoami:v1.11.0" ]; };
    vm-monitoring = { render = "render-monitoring"; apps = [ "monitoring" "nixlab-secrets" ]; extra = [ "docker.io/mendhak/http-https-echo:43" ]; };
    vm-monitoring-full = { render = "render-monitoring-full"; apps = [ "monitoring" "nixlab-secrets" ]; extra = [ "docker.io/mendhak/http-https-echo:43" ]; };
    vm-minimal = { render = "render-minimal"; apps = [ ]; extra = [ "docker.io/traefik/whoami:v1.11.0" ]; };
    vm-sso = { render = "render-sso-vm"; apps = [ "wireguard" "cert-manager" "cert-manager-issuers" "nixlab-secrets" ]; extra = [ ]; };
    vm-ha = { render = "render-ha"; apps = [ ]; extra = [ "docker.io/traefik/whoami:v1.11.0" ]; };
    # Longhorn names most of its images in environment variables and arguments
    # (it starts those components itself): also = what else to look for.
    vm-longhorn = {
      render = "render-longhorn-vm"; apps = [ "longhorn" ]; extra = [ "docker.io/library/alpine:3.22" ];
      also = "(docker\\.io/)?longhornio/(longhorn-(manager|engine|instance-manager)|csi-[a-z-]+|livenessprobe):[A-Za-z0-9._-]+";
    };
    vm-gateway = { render = "render-gateway-vm"; apps = [ "metallb" "metallb-config" "traefik" "cert-manager" "cert-manager-issuers" "haproxy" "whoami" ]; extra = [ ]; };
  };
  build = check: "nix build --no-link --print-out-paths .#checks.x86_64-linux.${check}";
  renders = lib.unique (map (t: t.render) (lib.attrValues vmTests));
  # The nixlab repo only: regenerate the VM tests' preloaded images.
  vmImages = ''
    echo "==> Updating the VM tests' images" >&2
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
        ${lib.optionalString (t ? also) (lib.concatMapStrings (app: ''
          grep -RhoE ${lib.escapeShellArg t.also} "$env/${app}" | sed -E 's|^longhornio/|docker.io/longhornio/|'
        '') t.apps)}
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
  runtimeInputs = with pkgs; [ nix git gh crane jq yq-go curl kubernetes-helm gnugrep gnused gawk coreutils findutils nix-prefetch-docker ];
  text = builtins.replaceStrings [ "@digestDirs@" "@chartsDir@" ] [ digestDirs chartsDir ] (builtins.readFile ./update.sh) + ''

    vm_images() {
      ${if library then vmImages else ":"}
    }
    # Checks to run for a unit: all of them for a flake input; for a chart or
    # image, the quick ones plus the VM tests whose apps changed.
    affected_tests() {
      local kind=$1
      ${if library then ''
        local all; all=$(nix eval --json .#checks.x86_64-linux --apply builtins.attrNames | jq -r '.[]')
        if [[ "$kind" == input ]]; then echo "$all"; return; fi
        grep -vxE 'host-.*|vm-.*' <<<"$all"
        ${lib.concatStrings (lib.mapAttrsToList (test: t: ''
          if ${if t.apps == [ ] then "false" else lib.concatMapStringsSep " || " (app: ''! diff -rq "''${before[${t.render}]}/${app}" "''${after[${t.render}]}/${app}" >/dev/null 2>&1'') t.apps}; then echo ${test}; fi
        '') vmTests)}
        # vm-cluster checks the whole default render against the API server.
        if ! diff -rq "''${before[render-default]}" "''${after[render-default]}" >/dev/null 2>&1; then echo vm-cluster; fi
      '' else ''
        # A homelab repo: its checks (the render, every node evaluates), and
        # every node built.
        nix eval --json .#checks.x86_64-linux --apply builtins.attrNames | jq -r '.[]'
        nix eval --json .#nixosConfigurations --apply builtins.attrNames | jq -r '.[] | "node:" + .'
      ''}
    }
    # The renders' store paths: "<render> <path>" lines.
    snapshot() {
      ${if library then ''
        local r
        for r in ${lib.concatStringsSep " " renders}; do echo "$r $(${build "$r"})"; done
      '' else ":"}
    }

    main "$@"
  '';
}
