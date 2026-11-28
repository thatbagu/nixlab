# NixOS VM test of upgrading from the previous release: its whole render is
# applied to a cluster for real, then the current render over it, the API
# server judging (server-side dry run, CRDs for real, like Argo CD applies
# them). Catches what only breaks on upgrade: a field that can't change on an
# existing object (a selector, a StatefulSet's volume templates, a Job's
# template), a CRD version still stored but no longer served.
#
# Webhook configurations are left out: their services don't run here.
{ pkgs, mkTestLab, testLib, inputs, allLayersOff, labArgs }:

let
  previousVersion = "v1.26.1";
  previous = builtins.fetchTarball {
    url = "https://github.com/thatbagu/nixlab/archive/refs/tags/${previousVersion}.tar.gz";
    sha256 = "0kfy859s76ah3nm7dm8zx81xxamc03k46j6j4zhc0kqhnhvhsq02";
  };
  # The previous release's code, with today's inputs (what changes between
  # releases is nixlab's own render; inputs have their own update checks).
  previousMkNixlab = import "${previous}/system/mk-nixlab.nix" { inherit inputs; };
  # (Arguments newer than that release, like secretsDir, it doesn't take.)
  before = (previousMkNixlab (removeAttrs labArgs [ "secretsDir" ])).nixidyEnv.environmentPackage;
  after = (mkTestLab { }).nixidyEnv.environmentPackage;

  # The cluster itself: k3s and nothing else.
  cluster = mkTestLab { secretsFile = ./secrets.yaml; overrides = allLayersOff; };
  k = "k3s kubectl";
  apply = pkgs.writeShellApplication {
    name = "apply-render";
    runtimeInputs = with pkgs; [ kubectl findutils gnugrep gawk ];
    text = ''
      # apply-render <env> <for real: yes|no>
      ENV=$1 real=$2
      mapfile -t crds < <(find -L "$ENV" -name 'CustomResourceDefinition-*.yaml' | sort)
      # CRDs for real either way (Argo CD applies them first).
      for f in "''${crds[@]}"; do kubectl apply --server-side --force-conflicts -f "$f" >/dev/null || { echo "CRD ''${f#"$ENV"/} rejected" >&2; exit 1; }; done
      kubectl wait --for=condition=Established --timeout=120s "''${crds[@]/#/-f}" >/dev/null
      mapfile -t namespaces < <(grep -RhoE '^  namespace: [a-z0-9-]+' "$ENV" | awk '{print $2}' | sort -u)
      for ns in "''${namespaces[@]}"; do
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      done
      dry=(); [[ $real == yes ]] || dry=(--dry-run=server)
      errors=0 count=0
      while IFS= read -r f; do
        count=$((count + 1))
        if ! out=$(kubectl apply "''${dry[@]}" --server-side --force-conflicts -f "$f" 2>&1); then
          # A Job's template can't change in place; Argo CD runs charts' Jobs
          # as hooks, deleting and recreating them. So a changed Job is checked
          # the way it'll be applied: as a new object (a renamed copy).
          if [[ $(basename "$f") == Job-* && $out == *"field is immutable"* ]] \
            && sed -E '0,/^  name: /s/^  name: (.*)$/  name: \1-upgrade-check/' "$f" | kubectl create --dry-run=server -f - >/dev/null 2>&1; then
            continue
          fi
          echo "''${f#"$ENV"/}: $out" >&2
          errors=$((errors + 1))
        fi
      # (Not KSOPS' Kustomize files or encrypted Secrets: they aren't
      # objects as they are, see validate.nix.)
      done < <(find -L "$ENV" -name '*.yaml' ! -name 'CustomResourceDefinition-*' ! -name '*WebhookConfiguration-*' ! -name kustomization.yaml ! -name ksops.yaml | sort \
        | while IFS= read -r f; do grep -q '^sops:' "$f" || echo "$f"; done)
      echo "''${#crds[@]} CRDs, $count objects, $errors rejected"
      [[ $errors -eq 0 ]]
    '';
  };
in
testLib.mkVmTest {
  name = "nixlab-upgrade";
  nodeName = "tmaster";
  specialArgs = cluster.specialArgsFor "tmaster";

  node = {
    imports = cluster.modulesFor "tmaster";
    virtualisation = {
      memorySize = 3072;
      cores = 2;
      diskSize = 4096;
      emptyDiskImages = [ 8192 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ];
  };

  subtests = [
    {
      name = "k3s comes up";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; }
      ];
    }
    {
      name = "the previous release's render (${previousVersion}), applied for real";
      steps = [ { succeed = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml ${apply}/bin/apply-render ${before} yes"; timeout = 900; } ];
    }
    {
      name = "the current render applies over it";
      steps = [ { succeed = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml ${apply}/bin/apply-render ${after} no"; timeout = 900; } ];
    }
  ];
}
