# NixOS VM test of profile = "single": the platform on one machine (the
# gateway, cert-manager's internal CA, Pi-hole, the VPN, a web app) and a
# client on the LAN. Checks that:
# - k3s keeps its state in SQLite (no etcd), and Longhorn, MetalLB and Argo
#   CD aren't installed: k3s applies the manifests itself
# - every service is on the node's own address (k3s' load balancer): the
#   client resolves the app's name with Pi-hole, to the node, and reaches the
#   app over HTTPS through the gateway; the VPN listens there too
# - and reports how much memory it all takes
{ pkgs, mkTestLab, testLib, singleVm }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-single;
  lab = mkTestLab (singleVm // { secretsFile = ./secrets.yaml; });
  k = "k3s kubectl";
  ip = "192.168.1.2"; # the node
  host = "whoami.yourdomain.example.com";
in
testLib.mkVmTest {
  name = "nixlab-single";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
      emptyDiskImages = [ 12288 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    # Preloaded images keep only their tag (no internet to resolve digests).
    modules.k8s.stripImageDigests = true;
  };

  extraNodes.client = {
    environment.systemPackages = [ pkgs.curl pkgs.dig ];
  };

  subtests = [
    {
      name = "one machine: SQLite, and none of the cluster-only parts";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; }
        { desc = "k3s keeps its state in SQLite"; succeed = "test -f /var/lib/rancher/k3s/server/db/state.db && ! test -d /var/lib/rancher/k3s/server/db/etcd"; }
        { desc = "no Longhorn, MetalLB or Argo CD";
          fail = "${k} get namespace longhorn-system metallb-system argocd 2>/dev/null | grep -c Active >/dev/null"; }
      ];
    }
    {
      name = "k3s deploys the platform";
      steps = map (w: { waitUntil = "${k} -n ${w} --timeout=10s"; timeout = 900; }) [
        "gateway-system rollout status deploy/traefik"
        "dns-system rollout status deploy/cert-manager"
        "pihole-system rollout status deploy/pihole"
        "dns-system rollout status deploy/externaldns-pihole-external-dns"
        "wireguard-system rollout status deploy/wireguard"
        "whoami rollout status deploy/whoami"
      ];
    }
    {
      name = "everything is on the node's address";
      steps = [
        { on = "client"; desc = "Pi-hole answers there and points the app's name at the node";
          waitUntil = "[ \"$(dig +short @${ip} ${host})\" = ${ip} ]"; timeout = 600; }
        { on = "client"; desc = "the app answers over HTTPS, through the gateway";
          waitUntil = "curl -fsk --resolve ${host}:443:${ip} https://${host}/ | grep -c Hostname >/dev/null"; timeout = 600; }
        { desc = "the VPN listens there (k3s' load balancer)";
          succeed = "${k} -n kube-system get pods -o wide | grep svclb-wireguard | grep -c Running >/dev/null"; }
      ];
    }
    {
      name = "how much it takes";
      steps = [
        # Settled: give the pods a minute, then report (and keep a ceiling).
        { succeed = "sleep 60"; }
        { desc = "memory in use (MB)"; succeed = "free -m | tee /dev/stderr | awk '/^Mem:/ { print \"used: \" $3 \" MB\" > \"/dev/stderr\"; exit !($3 < 3000) }'"; }
        { desc = "per namespace (kubectl top)"; succeed = "${k} top pods -A --no-headers 2>/dev/null | awk '{ m = $4; sub(/Mi/, \"\", m); ns[$1] += m } END { for (n in ns) printf \"%6d Mi  %s\\n\", ns[n], n }' | sort -rn >&2 || true"; }
      ];
    }
  ];

  onFailure = [
    "${k} get pods -A; ${k} get svc -A | grep LoadBalancer"
    { on = "client"; cmd = "dig @${ip} ${host}; curl -vk --resolve ${host}:443:${ip} https://${host}/ 2>&1 | tail -20"; }
  ];
}
