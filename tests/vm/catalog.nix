# NixOS VM test of a group of catalog apps (catalog/), on one machine without
# Kubernetes behind Caddy: each app turned on with apps.<name>.enable comes
# up, answers its health path over HTTPS through the gateway (Caddy's internal
# CA), and answers again after a restart (its data where it's kept).
{ pkgs, mkTestLab, testLib, name, apps, memory ? 3072 }:

let
  inherit (pkgs) lib;
  catalog = import ../../catalog { inherit lib; };
  domain = "home.arpa";
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    overrides = {
      profile = "single"; kubernetes.enable = false; cloudflare.enable = false; inherit domain;
      pihole.enable = false;
      apps = lib.genAttrs apps (_: { enable = true; });
    };
    replace.nodes.tmaster = { hostname = "tmaster"; master = true; disk = "/dev/vda"; tags = [ "homelab" "master" ]; address = "192.168.1.1"; };
  };
  rootCa = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt";
  native = lab.nixidyEnv.config.nixlab.nativeApps;
  # An app's systemd unit, as its NixOS module names it.
  unitOf = app: "${app}.service";
  # 2xx or 3xx (a login page may redirect) at its health path, through Caddy.
  answers = app: let host = native.${app}.host; in
    "[[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert ${rootCa} --resolve ${host}:443:127.0.0.1 https://${host}${catalog.${app}.meta.health}) =~ ^[23] ]]";
in
testLib.mkVmTest {
  name = "nixlab-${name}";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";
  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = memory;
      cores = 2;
      diskSize = 8192;
      emptyDiskImages = [ 4096 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    environment.systemPackages = [ pkgs.curl ];
  };

  subtests = [
    {
      name = "the gateway comes up";
      steps = [
        { waitForUnit = "multi-user.target"; timeout = 600; }
        { waitForUnit = "caddy.service"; timeout = 300; }
        { desc = "Caddy made its internal CA"; waitUntil = "test -s ${rootCa}"; timeout = 120; }
      ];
    }
  ] ++ map (app: {
    name = "${app}: up, through the gateway, and again after a restart";
    steps = [
      { waitForUnit = unitOf app; timeout = 600; }
      { desc = "${app} answers at https://${native.${app}.host}${catalog.${app}.meta.health}"; waitUntil = answers app; timeout = 300; }
      { succeed = "systemctl restart ${unitOf app}"; }
      { desc = "${app} answers again after a restart"; waitUntil = answers app; timeout = 300; }
    ];
  }) apps;

  onFailure = map (app: "systemctl status ${unitOf app} --no-pager | tail -15; journalctl -u ${unitOf app} --no-pager | tail -20") apps
    ++ [ "journalctl -u caddy --no-pager | tail -20" ];
}
