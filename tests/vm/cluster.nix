# NixOS VM test: boots the real master configuration (the same modules
# `colmena apply` deploys) and checks, on its own k3s:
# - sops-nix decrypts the secrets and k8s-secrets pushes them into the cluster
# - argocd-bootstrap installs a working Argo CD and the parent app, once
# - every rendered object is accepted by the API server
# - an app made with nixlab.webApp runs and answers HTTP
#
# The VM has no internet, so container images are fetched by Nix (pinned in
# images.nix) and preloaded into k3s.
{ pkgs, mkTestLab }:

let
  inherit (pkgs) lib;
  images = import ./images.nix { inherit pkgs; };

  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    extraAppModules = [
      ({ nixlab, ... }: nixlab.webApp {
        name = "whoami";
        # By tag: images preloaded into k3s keep their tag, not the registry digest.
        image = "docker.io/traefik/whoami:v1.11.0";
        port = 80;
        host = null;
      })
    ];
  };
  env = lab.nixidyEnv.environmentPackage;

  validate = pkgs.writeShellApplication {
    name = "validate";
    runtimeInputs = [ pkgs.kubectl pkgs.gawk pkgs.findutils ];
    text = builtins.readFile ./validate.sh;
  };
in
pkgs.testers.runNixOSTest {
  name = "nixlab-cluster";

  node.specialArgs = lab.specialArgsFor "tmaster";
  # The node config sets nixpkgs options (overlays, allowUnfree).
  node.pkgsReadOnly = false;

  nodes.tmaster = {
    imports = lab.modulesFor "tmaster";

    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
      # The VM replaces the disko layout. /persist gets its own disk like on a
      # real node: k3s' datastore and images live there (impermanence).
      emptyDiskImages = [ 16384 ];
      fileSystems."/persist" = {
        device = "/dev/vdb";
        fsType = "ext4";
        autoFormat = true;
        neededForBoot = true;
      };
    };

    # Put the published test-only key (tests/vm/secrets.yaml is encrypted to
    # it) where real nodes keep theirs, before sops-nix decrypts anything.
    # (sops-nix refuses a key file in the Nix store.)
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };

    services.k3s.images = [
      pkgs.k3s.passthru.airgap-images
      images.argocd
      images.redis
      images.whoami
    ];
    environment.systemPackages = [ validate pkgs.curl ];
  };

  testScript = ''
    def kubectl(cmd):
        return tmaster.succeed(f"k3s kubectl {cmd}")

    tmaster.start()

    with subtest("k3s comes up"):
        tmaster.wait_for_unit("k3s.service")
        tmaster.wait_until_succeeds("k3s kubectl get nodes | grep -w Ready", timeout=300)

    with subtest("SOPS secrets are decrypted and pushed into the cluster"):
        tmaster.wait_for_unit("k8s-secrets.service", timeout=300)
        kubectl("-n nextcloud get secret nextcloud-admin")
        kubectl("-n wireguard-system get secret wireguard-secrets")
        password = kubectl("-n nextcloud get secret nextcloud-admin -o jsonpath='{.data.password}' | base64 -d")
        assert password == "test-admin", f"nextcloud-admin password is {password!r}"

    with subtest("argocd-bootstrap installs Argo CD and the parent app"):
        tmaster.wait_for_unit("argocd-bootstrap.service", timeout=600)
        tmaster.wait_until_succeeds("k3s kubectl -n argocd rollout status deploy/argocd-server --timeout=10s", timeout=600)
        tmaster.wait_until_succeeds("k3s kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=10s", timeout=600)
        tmaster.wait_until_succeeds("k3s kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=10s", timeout=600)
        kubectl("-n argocd get application apps")
        # It can't reach the (placeholder) repo here; a reconcile proves Argo works.
        tmaster.wait_until_succeeds(
            "test -n \"$(k3s kubectl -n argocd get application apps -o jsonpath='{.status.reconciledAt}')\"",
            timeout=300)

    with subtest("bootstrap runs only once"):
        tmaster.succeed("systemctl restart argocd-bootstrap.service")
        tmaster.succeed("journalctl -u argocd-bootstrap.service --since=-1min | grep -q 'already bootstrapped'")

    with subtest("every rendered object is accepted by the API server"):
        print(tmaster.succeed("KUBECONFIG=/etc/rancher/k3s/k3s.yaml validate ${env}"))

    with subtest("a nixlab.webApp app runs and answers HTTP"):
        tmaster.succeed("for f in ${env}/whoami/*.yaml; do k3s kubectl apply -f $f; done")
        tmaster.wait_until_succeeds("k3s kubectl -n whoami rollout status deploy/whoami --timeout=10s", timeout=300)
        ip = kubectl("-n whoami get svc whoami -o jsonpath='{.spec.clusterIP}'")
        tmaster.wait_until_succeeds(f"curl -sf http://{ip}/ | grep -q 'Hostname: whoami'", timeout=120)
  '';
}
