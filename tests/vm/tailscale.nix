# NixOS VM test of remote access over Tailscale, against a Headscale server
# (the open-source Tailscale control server; the VMs have no internet). Four
# machines on two networks:
#   network 1 ("the internet"): headscale, client (your phone), tmaster
#   network 2 ("your LAN"):     tmaster, lanhost (a device at home)
# Checks that:
# - the master joins the tailnet with its auth key and advertises the LAN
# - the client, which can't reach the LAN directly, reaches lanhost through
#   the master once the route is approved
# - the node's tailnet identity is kept on /persist
{ pkgs, mkTestLab, testLib }:

let
  inherit (pkgs) lib;
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    overrides.tailscale = {
      enable = true;
      loginServer = "https://headscale";
      advertiseRoutes = [ "192.168.2.0/24" ];
    };
  };
  # Headscale's HTTPS certificate (self-signed, trusted by the tailnet nodes).
  cert = pkgs.runCommand "headscale-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes -subj /CN=headscale \
      -addext subjectAltName=DNS:headscale -keyout $out/key.pem -out $out/cert.pem
  '';
  # The key Headscale generates at runtime, where the node reads its auth key
  # (the SOPS secret in a real setup).
  keyFile = "/run/tailscale-test-auth-key";
in
testLib.mkVmTest {
  name = "nixlab-tailscale";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      vlans = [ 1 2 ];
      memorySize = 2048;
      emptyDiskImages = [ 2048 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    services.tailscale.authKeyFile = lib.mkForce keyFile;
    security.pki.certificateFiles = [ "${cert}/cert.pem" ];
    # Not under test here.
    services.k3s.enable = lib.mkForce false;
    environment.systemPackages = [ pkgs.jq ];
  };

  extraNodes = {
    headscale = {
      virtualisation.vlans = [ 1 ];
      services.headscale = {
        enable = true;
        port = 8080;
        settings = {
          server_url = "https://headscale";
          prefixes.v4 = "100.64.0.0/10";
          derp = {
            server = { enabled = true; region_id = 999; stun_listen_addr = "0.0.0.0:3478"; };
            urls = [ ];
          };
          dns = { base_domain = "tailnet"; override_local_dns = false; };
        };
      };
      services.nginx = {
        enable = true;
        virtualHosts.headscale = {
          addSSL = true;
          sslCertificate = "${cert}/cert.pem";
          sslCertificateKey = "${cert}/key.pem";
          locations."/" = { proxyPass = "http://127.0.0.1:8080"; proxyWebsockets = true; };
        };
      };
      networking.firewall = { allowedTCPPorts = [ 80 443 ]; allowedUDPPorts = [ 3478 ]; };
      environment.systemPackages = [ pkgs.headscale pkgs.jq pkgs.curl ];
    };
    client = {
      virtualisation.vlans = [ 1 ];
      services.tailscale.enable = true;
      security.pki.certificateFiles = [ "${cert}/cert.pem" ];
    };
    lanhost = {
      virtualisation.vlans = [ 2 ];
    };
  };

  subtests = [
    {
      name = "the master joins the tailnet and advertises the LAN";
      steps = [
        { on = "headscale"; waitForUnit = "headscale.service"; }
        { on = "headscale"; waitUntil = "curl -fsk https://headscale/health"; }
        { on = "headscale"; succeed = "headscale users create home"; }
        { on = "headscale"; desc = "a reusable key, like the one in secrets.yaml";
          succeed = "headscale preauthkeys create --user \"$(headscale users list -o json | jq -r '.[0].id')\" --reusable > /tmp/key"; }
        { copy = { from = "headscale"; path = "/tmp/key"; to = "tmaster"; dest = keyFile; }; }
        { succeed = "systemctl restart tailscaled-autoconnect.service"; }
        { waitUntil = "tailscale status --json | jq -e '.BackendState == \"Running\"'"; timeout = 120; }
        { desc = "it offers the LAN as a route";
          waitUntil = "tailscale debug prefs | jq -e '.AdvertiseRoutes | index(\"192.168.2.0/24\")'"; }
        { desc = "its tailnet identity lives on /persist";
          succeed = "test -n \"$(ls -A /persist/var/lib/tailscale)\""; }
      ];
    }
    {
      name = "the client reaches the LAN through it";
      steps = [
        { on = "client"; desc = "not directly: the client isn't on the LAN"; fail = "ping -c1 -W2 lanhost"; }
        { copy = { from = "headscale"; path = "/tmp/key"; to = "client"; dest = "/tmp/key"; }; }
        { on = "client"; succeed = "tailscale up --login-server https://headscale --auth-key \"$(cat /tmp/key)\" --accept-routes"; }
        { on = "headscale"; desc = "approve the route (Tailscale: autoApprovers in your ACL, see docs/remote-access.md)";
          waitUntil = "id=$(headscale nodes list -o json | jq -r '.[] | select(.name == \"tmaster\" or .given_name == \"tmaster\") | .id') && [ -n \"$id\" ] && headscale nodes approve-routes --identifier \"$id\" --routes 192.168.2.0/24"; timeout = 60; }
        { on = "client"; desc = "through the tailnet";
          waitUntil = "ping -c1 -W2 lanhost"; timeout = 120; }
      ];
    }
  ];

  onFailure = [
    "tailscale status; tailscale debug prefs | head -40; journalctl -u tailscaled -u tailscaled-autoconnect --no-pager | tail -30"
    { on = "headscale"; cmd = "headscale nodes list; headscale nodes list -o json | head -60; journalctl -u headscale --no-pager | tail -30"; }
    { on = "client"; cmd = "tailscale status; ip route show table 52; ip route"; }
  ];
}
