# NixOS VM test of a fresh cluster bootstrapping by itself, the way a real
# one does: Argo CD (or Flux, engine = "flux") syncs every layer (MetalLB, the gateway, cert-manager with
# the internal CA, Longhorn, Pi-hole, the VPN, a web app) from the rendered
# branch, which the machine serves itself as a git repository. Checks that,
# with nobody touching anything:
# - every Application ends up Synced and Healthy (sync waves, Longhorn's
#   one-time manual sync, a gateway whose certificates come later, Secrets
#   for namespaces another app creates); with Flux, every Kustomization but
#   the suspended Longhorn Ready
# - the web app answers HTTPS through the edge proxy and the gateway
#
# The VM has no internet: images are preloaded (images.nix), and the served
# branch drops their registry digests (preloaded images keep only the tag).
{ pkgs, mkTestLab, testLib, overrides, extraAppModules, engine ? "argocd", name ? null }:

let
  inherit (pkgs) lib;
  flux = engine == "flux";
  # The test's name (and its group of preloaded images, images.json).
  testName = if name != null then name else if flux then "vm-flux-bootstrap" else "vm-bootstrap";
  images = (import ./images.nix { inherit pkgs; }).${testName};
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides extraAppModules; };
  env = lab.nixidyEnv.environmentPackage;
  k = "k3s kubectl";
  bootstrap = if flux then "flux-bootstrap" else "argocd-bootstrap";
  # One line per app: name, then its state.
  apps = if flux
    then "${k} -n flux-system get kustomizations -o custom-columns='A:.metadata.name,R:.status.conditions[?(@.type==\"Ready\")].status,S:.spec.suspend' --no-headers"
    else "${k} -n argocd get applications -o custom-columns=A:.metadata.name,S:.status.sync.status,H:.status.health.status --no-headers";
  # The apps that aren't there yet (Longhorn stays suspended with Flux).
  notDone = if flux
    then "${apps} | awk '$3 != \"true\" && $2 != \"True\"'"
    else "${apps} | grep -v 'Synced *Healthy'";
in
testLib.mkVmTest {
  name = "nixlab-" + lib.removePrefix "vm-" testName;
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 8192;
      cores = 6;
      diskSize = 8192;
      emptyDiskImages = [ 24576 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    networking.firewall.allowedTCPPorts = [ 7946 ];
    networking.firewall.allowedUDPPorts = [ 7946 ];
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    # What the master applies from the render itself (Cilium's bootstrap):
    # by tag, like the served branch.
    modules.k8s.stripImageDigests = true;
    environment.systemPackages = [ pkgs.curl ];

    # The rendered branch, as CI pushes it, over git's smart HTTP protocol
    # (Argo CD's go-git doesn't speak the plain one; gitRepository in the lab
    # points here).
    systemd.services.rendered-repo = {
      wantedBy = [ "multi-user.target" ];
      before = [ "${bootstrap}.service" ];
      path = with pkgs; [ git gnused python3 ];
      script = ''
        rm -rf /run/rendered /srv/git; mkdir -p /run/rendered /srv/git
        cp -rL ${env}/. /run/rendered/ && chmod -R u+w /run/rendered
        find /run/rendered -name '*.yaml' -exec sed -i -E 's/@sha256:[0-9a-f]{64}//' {} +
        cd /run/rendered
        git init -q -b k8s-rendered && git add -A
        git -c user.email=ci@test -c user.name=ci commit -qm render
        git clone -q --bare /run/rendered /srv/git/rendered.git
        exec python3 ${./git-http.py} /srv/git 8000
      '';
    };
  };

  subtests = [
    {
      name = "the cluster comes up and ${if flux then "Flux" else "Argo CD"} bootstraps it";
      steps = [
        { waitForUnit = "k3s.service"; }
        # k3s imports every preloaded image before its kubelet starts: minutes.
        { waitUntil = "${k} get nodes | grep -w Ready"; timeout = 1800; }
        { waitForUnit = "rendered-repo.service"; }
        { waitUntil = "curl -sf http://192.168.1.1:8000/rendered.git/info/refs | grep -c k8s-rendered"; }
        { waitForUnit = "${bootstrap}.service"; timeout = 600; }
      ];
    }
    {
      name = "every app ends up ${if flux then "Ready" else "Synced and Healthy"}, by itself";
      steps = [
        { desc = "all of them exist";
          waitUntil = "[ $(${apps} | wc -l) -ge ${toString (builtins.length (builtins.attrNames lab.nixidyEnv.config.applications) - 1)} ]"; timeout = 1800; }
        { desc = "and all of them are ${if flux then "Ready" else "Synced and Healthy"}";
          waitUntil = "${apps} >&2; [ -z \"$(${notDone})\" ]"; timeout = 2400; }
      ];
    }
    {
      name = "the web app answers through the edge proxy and the gateway";
      steps = [
        { waitUntil = "curl -skf --resolve whoami.yourdomain.example.com:443:192.168.1.193 https://whoami.yourdomain.example.com/ | grep -c Hostname"; timeout = 600; }
      ];
    }
    {
      name = "Longhorn's first sync went through without help";
      steps = lib.optional (!flux)
        { succeed = "[ \"$(${k} -n argocd get application longhorn -o jsonpath='{.status.operationState.phase}')\" = Succeeded ]"; }
      ++ lib.optional flux
        { desc = "and Flux leaves it alone (suspended)";
          succeed = "[ \"$(${k} -n flux-system get kustomization longhorn -o jsonpath='{.spec.suspend}')\" = true ]"; }
      ++ [
        { succeed = "${k} -n longhorn-system get nodes.longhorn.io tmaster"; }
      ];
    }
  ];

  onFailure = [
    "${apps}"
    (if flux
      then "${k} -n flux-system get kustomizations,gitrepositories -o json | ${pkgs.jq}/bin/jq -r '.items[] | select(.spec.suspend != true) | (.status.conditions // [] | map(select(.type == \"Ready\")) | first) as $r | select($r.status != \"True\") | \"\\(.kind)/\\(.metadata.name): \\($r.reason // \"-\") \\($r.message // \"\" | .[0:300])\"'"
      else "${k} -n argocd get applications -o json | ${pkgs.jq}/bin/jq -r '.items[] | select(.status.sync.status != \"Synced\" or .status.health.status != \"Healthy\") | \"\\(.metadata.name): \\(.status.operationState.phase // \"-\") \\(.status.operationState.message // \"\" | .[0:300])\"'")
    "${k} get pods -A | grep -vE 'Running|Completed'"
    # Why a node isn't Ready (e.g. no pod network), and the pod network itself.
    "${k} get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.conditions[*]}{.type}={.status} {.message}; {end}{\"\\n\"}{end}'"
    "${k} -n kube-system get daemonsets,pods -o wide"
    "${k} -n kube-system logs ds/cilium --tail=40 --all-containers 2>&1 | tail -40"
    "ls -la /var/lib/rancher/k3s/agent/etc/cni/net.d /var/lib/rancher/k3s/data/cni 2>&1 | head -30"
    "journalctl -u ${bootstrap} --no-pager | tail -30"
  ];
}
