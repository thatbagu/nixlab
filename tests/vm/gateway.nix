# NixOS VM test of the gateway (Traefik on the Gateway API), with two
# machines: the real master configuration (the gateway, cert-manager with the
# internal CA, the edge proxy, a web app) and a separate client. Checks that:
# - the app's host gets an HTTPS listener with a cert-manager certificate,
#   and the app answers through it with a certificate the CA vouches for
# - plain HTTP redirects to HTTPS
# - behind the edge proxy, the app sees the client's real address (the PROXY
#   protocol from HAProxy to Traefik)
{ pkgs, mkTestLab, testLib, overrides, extraAppModules }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-gateway;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides extraAppModules; };
  host = "whoami.yourdomain.example.com";
  listener = "https-whoami-yourdomain-example-com";
  k = "k3s kubectl";
in
testLib.mkVmTest {
  name = "nixlab-gateway";
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
    # The edge proxy's ports (MetalLB is off: k3s' own load balancer uses the node).
    networking.firewall.allowedTCPPorts = [ 80 443 ];
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    # Preloaded images keep only their tag (no internet to resolve digests).
    modules.k8s.stripImageDigests = true;
    environment.systemPackages = [ pkgs.curl ];
  };

  extraNodes.client = { ... }: {
    environment.systemPackages = [ pkgs.curl ];
  };

  subtests = [
    {
      name = "the gateway and its certificate come up";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; }
        { waitUntil = "${k} -n gateway-system rollout status deploy/traefik --timeout=10s"; timeout = 600; }
        { desc = "cert-manager issues the app's listener certificate";
          waitUntil = "${k} -n gateway-system wait --for=condition=Ready certificate/${listener} --timeout=10s"; timeout = 900; }
        { waitUntil = "${k} -n gateway-system wait --for=condition=Programmed gateway/nixlab --timeout=10s"; timeout = 300; }
        { waitUntil = "${k} -n whoami rollout status deploy/whoami --timeout=10s"; timeout = 300; }
        { waitUntil = "${k} -n gateway-system rollout status deploy/haproxy --timeout=10s"; timeout = 300; }
      ];
    }
    {
      name = "the app answers over HTTPS, with a trusted certificate";
      steps = [
        { succeed = "${k} -n gateway-system get secret ${listener} -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/ca.crt"; }
        { desc = "verified against the internal CA";
          waitUntil = "curl -sS --max-time 10 --cacert /tmp/ca.crt --resolve ${host}:443:127.0.0.1 https://${host}/ | grep -c '^Hostname: whoami' >/dev/null"; timeout = 300; }
        { desc = "plain HTTP redirects to HTTPS";
          succeed = "r=$(curl -s --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' --resolve ${host}:80:127.0.0.1 http://${host}/); echo \"redirect: $r\"; [ \"$r\" = '301 https://${host}/' ]"; }
      ];
    }
    {
      name = "the app sees the client's real address through the edge proxy";
      steps = [
        { on = "client"; desc = "X-Forwarded-For is the client, not the edge proxy";
          waitUntil = "curl -sk --max-time 10 --resolve ${host}:443:$(getent ahostsv4 tmaster | head -1 | cut -d' ' -f1) https://${host}/ | grep -c \"^X-Forwarded-For: $(ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1)\" >/dev/null"; timeout = 120; }
      ];
    }
  ];

  onFailure = [
    "curl -sv --max-time 10 --resolve ${host}:80:127.0.0.1 http://${host}/ 2>&1 | grep -E '^[<>] '"
    "${k} get pods -A -o wide"
    "${k} -n gateway-system get gateway nixlab -o yaml | tail -60"
    "${k} get httproute -A -o yaml | grep -A12 'status:'"
    "${k} -n gateway-system get certificate,certificaterequest,secret"
    "${k} -n gateway-system describe certificate | tail -30"
    "${k} -n gateway-system logs deploy/traefik --tail=60"
    "${k} -n gateway-system logs deploy/haproxy --tail=30"
    "${k} -n dns-system logs deploy/cert-manager --tail=40"
    "${k} get svc -A -o wide"
    { on = "client"; cmd = "ip -4 -o addr; getent ahostsv4 tmaster; curl -sk -v --max-time 10 --resolve ${host}:443:$(getent ahostsv4 tmaster | head -1 | cut -d' ' -f1) https://${host}/"; }
  ];
}
