# NixOS VM test of single sign-on, end to end, with two machines: the real
# master configuration (VPN, cert-manager, Dex) and a separate WireGuard
# client, "alice". Checks that:
# - alice gets signed in over the VPN with no password or prompt: a real OIDC
#   authorization-code login against https://auth.<domain> returns an ID
#   token for "alice"
# - alice can't impersonate anyone: sending X-Remote-User: bob still gets her
#   a token for alice
# - nobody outside the VPN gets an identity: a request from the cluster (not
#   a VPN address) with a forged X-Remote-User: alice gets no login
# - pods reach the provider at auth.<domain> (the cluster DNS rewrite)
{ pkgs, mkTestLab, testLib, overrides }:

let
  inherit (pkgs) lib;
  images = (import ./images.nix { inherit pkgs; }).vm-sso;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides; };
  domain = "yourdomain.example.com";
  authHost = "auth.${domain}";
  k = "k3s kubectl";

  # The server's WireGuard public key (tests/vm/secrets.yaml).
  serverPublicKey = "xHj/P5VNjPgwh/3dk0M+PV8O8TFV+5JSQIxKIpw2m3g=";

  # A minimal OIDC client: the authorization-code flow against Dex through
  # the given address, printing the ID token's "name" claim (fails without a
  # login). Extra arguments go to every curl call (e.g. a forged header).
  oidcLogin = pkgs.writeShellApplication {
    name = "oidc-login";
    runtimeInputs = with pkgs; [ curl jq coreutils gnused ];
    text = ''
      ip=$1; shift
      c=(curl -sk --max-time 20 --resolve "${authHost}:443:$ip" "$@")
      url="https://${authHost}/auth?client_id=vm-test&redirect_uri=http%3A%2F%2Flocalhost%2Fcallback&response_type=code&scope=openid+profile&state=vmtest"
      code=""
      for _ in 1 2 3 4 5 6 7 8; do
        next=$("''${c[@]}" -o /dev/null -w '%{redirect_url}' "$url")
        case "$next" in
          http://localhost/callback*) code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$next"); break ;;
          "") echo "no redirect from $url" >&2; exit 1 ;;
          *) url=$next ;;
        esac
      done
      [[ -n "$code" ]] || { echo "no authorization code" >&2; exit 1; }
      token=$("''${c[@]}" -X POST "https://${authHost}/token" \
        -d grant_type=authorization_code -d "code=$code" \
        -d redirect_uri=http://localhost/callback -d client_id=vm-test | jq -r .id_token)
      payload=$(cut -d. -f2 <<<"$token" | tr '_-' '/+')
      while (( ''${#payload} % 4 )); do payload="$payload="; done
      base64 -d <<<"$payload" | jq -r .name
    '';
  };
in
testLib.mkVmTest {
  name = "nixlab-sso";
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
    # The VPN's port (MetalLB is off: k3s' own load balancer uses the node).
    networking.firewall.allowedUDPPorts = [ 51820 ];
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    # Preloaded images keep only their tag (no internet to resolve digests).
    modules.k8s.stripImageDigests = true;
    environment.systemPackages = [ oidcLogin ];
  };

  extraNodes.client = { nodes, ... }: {
    networking.wg-quick.interfaces.wg0 = {
      address = [ "10.0.100.2/32" ]; # alice (tests/default.nix)
      privateKeyFile = "${./alice-wg-private.key}";
      peers = [{
        publicKey = serverPublicKey;
        # By IPv4: the test network also gives tmaster an IPv6 address, which
        # the (IPv4-only) cluster doesn't listen on.
        endpoint = "${nodes.tmaster.networking.primaryIPAddress}:51820";
        allowedIPs = [ "10.0.100.0/24" ];
        persistentKeepalive = 5;
      }];
    };
    environment.systemPackages = [ oidcLogin pkgs.iputils ];
  };

  subtests = [
    {
      name = "the VPN pod runs with Dex, behind a certificate";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; }
        { waitForUnit = "k8s-secrets.service"; }
        { waitUntil = "${k} -n wireguard-system wait --for=condition=Ready certificate/nextcloud-tls --timeout=10s"; timeout = 900; }
        { waitUntil = "${k} -n wireguard-system rollout status deploy/wireguard --timeout=10s"; timeout = 600; }
      ];
    }
    {
      name = "pods reach the provider at auth.<domain>";
      steps = [
        # A separate pod, like an app (e.g. Nextcloud) exchanging a code.
        { succeed = "${k} -n default run probe --image=docker.io/library/alpine:3.22 --image-pull-policy=IfNotPresent --restart=Never --command -- sleep 3600"; }
        { waitUntil = "${k} -n default wait --for=condition=Ready pod/probe --timeout=10s"; }
        { desc = "auth.<domain> resolves to the VPN pod's proxy Service (cluster DNS rewrite)";
          waitUntil = "${k} -n default exec probe -- nslookup ${authHost} | grep -c \"$(${k} -n wireguard-system get svc wireguard-proxy -o jsonpath='{.spec.clusterIP}')\" >/dev/null"; }
        { desc = "and serves the provider's discovery document";
          waitUntil = "${k} -n default exec probe -- wget -qO- --no-check-certificate https://${authHost}/.well-known/openid-configuration | grep -c '\"issuer\": *\"https://${authHost}\"' >/dev/null"; }
      ];
    }
    {
      name = "alice connects to the VPN";
      steps = [
        { on = "client"; waitForUnit = "wg-quick-wg0.service"; }
        { on = "client"; waitUntil = "ping -c1 -W2 10.0.100.1"; timeout = 300; }
      ];
    }
    {
      name = "alice is signed in without a password";
      steps = [
        { on = "client"; desc = "a real OIDC login returns an ID token for alice";
          waitUntil = "[ \"$(oidc-login 10.0.100.1)\" = alice ]"; timeout = 120; }
      ];
    }
    {
      name = "nobody can impersonate anyone";
      steps = [
        { on = "client"; desc = "alice claiming to be bob still gets alice";
          succeed = "[ \"$(oidc-login 10.0.100.1 -H 'X-Remote-User: bob')\" = alice ]"; }
        { desc = "a non-VPN address with a forged header gets no login";
          fail = "oidc-login \"$(${k} -n wireguard-system get svc wireguard-proxy -o jsonpath='{.spec.clusterIP}')\" -H 'X-Remote-User: alice'"; }
      ];
    }
  ];

  onFailure = [
    { on = "client"; cmd = "wg show; getent hosts tmaster; ip route"; }
    "${k} -n wireguard-system exec deploy/wireguard -c wireguard -- wg show"
    "${k} -n wireguard-system logs deploy/wireguard -c wireguard --tail=80"
    "${k} -n wireguard-system logs deploy/wireguard -c setup-config --tail=20"
    "${k} -n wireguard-system exec deploy/wireguard -c wireguard -- ip -br link"
    "lsmod | grep -i wireguard; dmesg | grep -i wireguard | tail -5"
    "${k} -n kube-system get pods -o wide -l svccontroller.k3s.cattle.io/svcname=wireguard"
    "${k} -n wireguard-system get svc -o wide"
    "ip -br addr; iptables -t nat -S | grep -c 51820"
    "${k} get pods -A -o wide"
    "${k} -n kube-system exec deploy/coredns -- cat /etc/coredns/custom/nixlab-sso.override"
    "${k} -n kube-system logs deploy/coredns --tail=30"
    "${k} -n default exec probe -- nslookup ${authHost}"
    "${k} -n default exec probe -- wget -O- --no-check-certificate https://${authHost}/.well-known/openid-configuration"
    "${k} -n wireguard-system describe pod | tail -30"
    "${k} -n wireguard-system describe certificate nextcloud-tls | tail -20"
    "${k} -n wireguard-system logs deploy/wireguard -c dex --tail=40"
    "${k} -n wireguard-system logs deploy/wireguard -c caddy --tail=40"
  ];
}
