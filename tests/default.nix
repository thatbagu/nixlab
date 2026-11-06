# Everything `nix flake check` tests, in Nix. The template's vars.nix has only
# placeholders, so the tests build a small fake homelab (two nodes, two VPN
# users, example secrets) and variants of it, each made with the same
# mkNixlab your real config uses.
{ inputs, pkgs, mkNixlab, mkFlake, mkTools }:

let
  inherit (pkgs) lib;
  testLib = import ./lib.nix { inherit pkgs; };

  templateVars = import ../template/vars.nix;
  # The helpers as a homelab repo made from template/ gets them.
  tools = mkTools { vars = templateVars; };

  # The fake homelab every variant starts from: your vars.nix (placeholders in
  # the template) with test nodes and VPN users in place of yours.
  baseVars = templateVars // {
    username = "ci";
    nodes = {
      tmaster = { hostname = "tmaster"; master = true; disk = "/dev/vda"; tags = [ "homelab" "master" ]; };
      tworker = { hostname = "tworker"; master = false; disk = "/dev/vda"; tags = [ "homelab" "worker" ]; };
    };
    wireguardUsers = {
      alice = { ip = "10.0.100.2"; group = "admin"; publicKeySecret = "alice_wg_public_key"; allowedIPs = "0.0.0.0/0"; nextcloudUser = "alice"; description = "test"; enabled = true; };
      bob = { ip = "10.0.100.3"; group = "family"; publicKeySecret = "bob_wg_public_key"; allowedIPs = "10.0.100.0/24"; description = "test"; enabled = true; };
    };
  };

  # The example secrets plus every optional key. sops-nix checks at build time
  # that declared secrets exist (it never decrypts them during the build). It
  # also needs the file in the store at evaluation time, hence toFile.
  testSecrets = builtins.toFile "secrets.yaml" (builtins.readFile ../template/secrets.yaml.example + ''
    alice_wg_public_key: "test"
    bob_wg_public_key: "test"
    backup_s3_access_key_id: "test"
    backup_s3_secret_access_key: "test"
    grafana_admin_password: "test"
    monitoring_telegram_bot_token: "test"
    monitoring_discord_webhook_url: "test"
    monitoring_smtp_password: "test"
    monitoring_webhook_url: "test"
    monitoring_deadmans_switch_url: "test"
  '');

  mkTestLab = { overrides ? { }, extraAppModules ? [ ], extraNixosModules ? [ ], secretsFile ? testSecrets }: mkNixlab {
    vars = lib.recursiveUpdate baseVars overrides;
    inherit secretsFile;
    hardwareConfig = _: ../template/hosts/example/hardware-configuration.nix;
    inherit extraAppModules extraNixosModules;
  };

  allLayersOff = {
    gitops.enable = false;
    metallb.enable = false;
    ingress.enable = false;
    certManager.enable = false;
    longhorn.enable = false;
    pihole.enable = false;
    vpn.enable = false;
    cloudflare.enable = false;
    nextcloud.enable = false;
    signalProxy.enable = false;
  };

  allChannels = {
    telegram = { enable = true; chatId = 123456; };
    discord.enable = true;
    email.enable = true;
    webhook.enable = true;
    deadMansSwitch.enable = true;
  };

  # Configuration variants: each must render and its master must evaluate.
  variants = {
    default = { };
    no-cloudflare.overrides = { cloudflare.enable = false; domain = "home.arpa"; };
    # Nothing at the old hardcoded addresses: another VPN subnet and LAN, an
    # ARM worker, users in the new subnet.
    custom-network.overrides = {
      vpn.subnet = "10.8.0.0/24";
      lan.subnet = "192.168.50.0/24";
      nodes.tworker.system = "aarch64-linux";
      wireguardUsers = {
        alice = baseVars.wireguardUsers.alice // { ip = "10.8.0.2"; };
        bob = baseVars.wireguardUsers.bob // { ip = "10.8.0.3"; allowedIPs = "10.8.0.0/24"; };
      };
    };
    # Every layer off: k3s on NixOS and nothing else.
    minimal.overrides = allLayersOff;
    # Just Argo CD on k3s, for your own apps.
    argocd-only.overrides = allLayersOff // { gitops.enable = true; };
    # The whole platform without Argo CD (k3s applies the manifests).
    no-gitops.overrides.gitops.enable = false;
    # k3s' local-path storage instead of Longhorn.
    local-storage.overrides.longhorn.enable = false;
    # Just the platform: no built-in apps.
    core-only.overrides = { nextcloud.enable = false; signalProxy.enable = false; backups.enable = true; };
    backups-s3.overrides.backups = { enable = true; s3Endpoint = "https://s3.example.com"; };
    backups-nfs-offsite.overrides.backups = {
      enable = true;
      target = "nfs://192.168.1.10:/volume1/backups";
      offsite.enable = true;
    };
    monitoring.overrides.monitoring = { enable = true; alerts = allChannels; };
    monitoring-full.overrides.monitoring = { enable = true; flavor = "full"; alerts = allChannels; };
    example-app.extraAppModules = [ ../template/apps/_example.nix ];
    # What `nix run .#new-app` writes must render.
    scaffolded-app.extraAppModules = [
      (builtins.toFile "scaffolded.nix" (builtins.replaceStrings
        [ "@NAME@" "@IMAGE@" "@PORT@" ] [ "scaffolded" "docker.io/traefik/whoami:v1.11.0" "80" ]
        tools.new-app.templateText))
    ];
  };
  labs = builtins.mapAttrs (_: mkTestLab) variants;

  # The deployed apps (not nixidy's own app-of-apps entries).
  apps = env: lib.subtractLists [ "apps" "__bootstrap" ] (lib.attrNames env.config.applications);
  hasApp = env: name: lib.elem name (apps env);
  master = lab: lab.nixosConfigurations.tmaster.config;

  # A check that passes when every assertion holds, and otherwise fails with
  # the messages of those that don't.
  expect = name: assertions:
    let failed = lib.filter (a: !a.ok) assertions;
    in if failed == [ ]
      then pkgs.runCommand "test-${name}" { } "touch $out"
      else throw "test ${name} failed:\n${lib.concatMapStringsSep "\n" (a: "  - ${a.msg}") failed}";
  is = ok: msg: { inherit ok msg; };

  secretsScript = lab: (master lab).systemd.services.k8s-secrets.script;
  # vars.nix -> internal settings, the way the modules see them.
  k8sVars = overrides: import ../system/k8s/vars.nix (lib.recursiveUpdate baseVars overrides);
in

# Every variant renders.
lib.mapAttrs' (name: lab: lib.nameValuePair "render-${name}" lab.nixidyEnv.environmentPackage) labs

# Every variant's master evaluates (forcing the whole configuration without
# building it); the default master and worker build completely.
// lib.mapAttrs' (name: lab: lib.nameValuePair "eval-${name}"
  (pkgs.writeText "eval-${name}" (master lab).system.build.toplevel.drvPath)) labs
// {
  host-master = labs.default.nixosConfigurations.tmaster.config.system.build.toplevel;
  host-worker = labs.default.nixosConfigurations.tworker.config.system.build.toplevel;

  # What each layer switch turns on and off.
  layers = let
    k3sFlags = lab: (master lab).services.k3s.extraFlags;
    manifests = lab: lib.attrNames (master lab).services.k3s.manifests;
  in expect "layers" [
    (is (apps labs.minimal.nixidyEnv == [ ]) "minimal: nothing is deployed on k3s")
    (is (!((master labs.minimal).systemd.services ? argocd-bootstrap)) "minimal: no Argo CD bootstrap")
    (is (manifests labs.minimal == [ ]) "minimal: nothing in k3s' auto-deploy directory")
    (is (!lib.hasInfix "create secret" (secretsScript labs.minimal)) "minimal: no secrets pushed")
    (is (!lib.hasInfix "--disable=servicelb" (k3sFlags labs.minimal) && !lib.hasInfix "--disable=local-storage" (k3sFlags labs.minimal))
      "minimal: k3s keeps its own load balancer and local storage")
    (is (apps labs.argocd-only.nixidyEnv == [ "argocd" ]) "argocd-only: just Argo CD")
    (is ((master labs.argocd-only).systemd.services ? argocd-bootstrap) "argocd-only: Argo CD bootstraps")
    (is (!hasApp labs.no-gitops.nixidyEnv "argocd") "no-gitops: no Argo CD")
    (is (!((master labs.no-gitops).systemd.services ? argocd-bootstrap)) "no-gitops: no bootstrap")
    (is (lib.elem "nixlab-pihole" (manifests labs.no-gitops) && lib.elem "nixlab-nextcloud" (manifests labs.no-gitops))
      "no-gitops: k3s gets every app from its auto-deploy directory")
    (is (manifests labs.default == [ ]) "with Argo CD, k3s' auto-deploy directory stays empty")
    (is (!hasApp labs.local-storage.nixidyEnv "longhorn") "local-storage: no Longhorn")
    (is (lib.hasInfix "local-path" (builtins.toJSON labs.local-storage.nixidyEnv.config.applications.wireguard.resources))
      "local-storage: volumes use local-path")
    (is (!lib.hasInfix "--disable=local-storage" (k3sFlags labs.local-storage)) "local-storage: k3s' local-path provisioner runs")
    (is (lib.hasInfix "--disable=servicelb" (k3sFlags labs.default) && lib.hasInfix "--disable=local-storage" (k3sFlags labs.default))
      "default: MetalLB and Longhorn replace k3s' load balancer and storage")
  ];

  # What each switch turns on and off.
  features = expect "features" [
    (is (lib.hasInfix "10.8.0.1/24" (builtins.toJSON labs.custom-network.nixidyEnv.config.applications.wireguard.resources))
      "the VPN server takes .1 of vpn.subnet")
    (is (labs.custom-network.nixosConfigurations.tworker.config.nixpkgs.hostPlatform.system == "aarch64-linux")
      "a node with system = aarch64-linux is built for ARM")
    (is (labs.default.nixosConfigurations.tmaster.config.time.timeZone == "UTC") "the default timezone is UTC")
    (is (hasApp labs.default.nixidyEnv "externaldns-cloudflare") "Cloudflare on: ExternalDNS for Cloudflare deployed")
    (is (!hasApp labs.no-cloudflare.nixidyEnv "externaldns-cloudflare") "Cloudflare off: no ExternalDNS for Cloudflare")
    (is (!hasApp labs.no-cloudflare.nixidyEnv "cloudflare-ddns") "Cloudflare off: no DDNS")
    (is (!hasApp labs.no-cloudflare.nixidyEnv "signal-proxy") "Cloudflare off: no Signal proxy")
    (is (!lib.hasInfix "cloudflare-api-token" (secretsScript labs.no-cloudflare)) "Cloudflare off: the token isn't pushed")
    (is (!hasApp labs.default.nixidyEnv "backups") "backups are off by default")
    (is (hasApp labs.default.nixidyEnv "nextcloud" && hasApp labs.default.nixidyEnv "signal-proxy") "Nextcloud and the Signal proxy are on by default")
    (is (!hasApp labs.core-only.nixidyEnv "nextcloud") "nextcloud.enable = false: no Nextcloud")
    (is (!hasApp labs.core-only.nixidyEnv "signal-proxy") "signalProxy.enable = false: no Signal proxy")
    (is (!hasApp labs.core-only.nixidyEnv "nextcloud-db-dump") "no Nextcloud: backups without the DB dump")
    (is (hasApp labs.core-only.nixidyEnv "backups") "no Nextcloud: volume backups still work")
    (is (!lib.hasInfix "nextcloud" (secretsScript labs.core-only)) "no Nextcloud: none of its secrets are pushed")
    (is (!lib.hasInfix "caddy" (builtins.toJSON labs.core-only.nixidyEnv.config.applications.wireguard.resources))
      "no Nextcloud: the VPN pod runs without the Caddy proxy")
    (is (!lib.hasInfix "nextcloud" (builtins.toJSON labs.core-only.nixidyEnv.config.applications.pihole.resources))
      "no Nextcloud: no Nextcloud DNS record in Pi-hole")
    (is (hasApp labs.backups-s3.nixidyEnv "backups" && hasApp labs.backups-s3.nixidyEnv "nextcloud-db-dump") "backups on: backups and DB dump apps")
    (is (lib.hasInfix "backup-s3" (secretsScript labs.backups-s3)) "S3 backups: the S3 keys are pushed")
    (is (lib.hasInfix "AWS_ENDPOINTS=https://s3.example.com" (secretsScript labs.backups-s3)) "S3 backups: the endpoint is pushed")
    (is (!hasApp labs.default.nixidyEnv "monitoring") "monitoring is off by default")
    (is (hasApp labs.monitoring.nixidyEnv "monitoring") "monitoring on: monitoring app")
    (is (labs.monitoring.nixidyEnv.config.applications.monitoring.helm.releases ? prometheus)
      "the light flavor (default) is plain Prometheus")
    (is (labs.monitoring-full.nixidyEnv.config.applications.monitoring.helm.releases ? kube-prometheus-stack)
      "the full flavor is kube-prometheus-stack")
    (is (lib.hasInfix "alertmanager-notifications" (secretsScript labs.monitoring)) "monitoring on: notification secrets are pushed")
    (is (lib.hasInfix "grafana-admin" (secretsScript labs.monitoring)) "monitoring on: Grafana's admin secret is pushed")
    (is (hasApp labs.example-app.nixidyEnv "uptime-kuma") "apps/: extra app modules are deployed")
    (is (hasApp labs.scaffolded-app.nixidyEnv "scaffolded") "a new-app scaffold renders as an app")
    (is ((master labs.default).systemd.services ? argocd-bootstrap) "the master bootstraps Argo CD")
    (is ((master labs.default).system.autoUpgrade.flake == "git+https://github.com/youruser/nixlab.git?ref=main#tmaster")
      "nodes self-upgrade from main of gitRepository")
    (is ((master labs.default).system.autoUpgrade.dates == "03:30"
      && labs.default.nixosConfigurations.tworker.config.system.autoUpgrade.dates == "03:45")
      "the master upgrades first, the worker spacingMinutes later")
    (is (!(master (mkTestLab { overrides.autoUpgrade.enable = false; })).system.autoUpgrade.enable)
      "autoUpgrade can be turned off")
    (is (!(labs.default.nixosConfigurations.tworker.config.systemd.services ? argocd-bootstrap)) "workers don't")
  ];

  # With another VPN subnet and LAN, none of the default addresses remain in
  # the rendered manifests (checked on the real output).
  custom-network-addresses = pkgs.runCommand "custom-network-addresses" { } ''
    render=${labs.custom-network.nixidyEnv.environmentPackage}
    # -R: the render is a tree of symlinks.
    matches=$(grep -RlE '10\.0\.100\.|192\.168\.1\.0/24' "$render" || true)
    if [ -n "$matches" ]; then echo "default addresses left in: $matches"; exit 1; fi
    grep -Rq '10\.8\.0\.1/24' "$render/wireguard" || { echo "the VPN server isn't 10.8.0.1"; exit 1; }
    touch $out
  '';

  # Bad settings are refused with a clear message.
  validation = expect "validation" [
    (is ((k8sVars { vpn.enable = false; pihole.enable = false; }).errors
      == [ "nextcloud.enable needs vpn.enable = true" "nextcloud.enable needs pihole.enable = true" ])
      "Nextcloud without its layers is reported")
    (is ((k8sVars { ingress.enable = false; }).errors == [ "signalProxy.enable needs ingress.enable = true" ])
      "the Signal proxy without ingress is reported")
    (is ((k8sVars { longhorn.enable = false; backups.enable = true; }).errors == [ "backups.enable needs longhorn.enable = true" ])
      "backups without Longhorn are reported")
    (is ((k8sVars allLayersOff).errors == [ ]) "everything off is a valid setup")
    (is (!(builtins.tryEval (mkTestLab { overrides.vpn.enable = false; }).nixidyEnv.environmentPackage.drvPath).success)
      "the render refuses a broken combination")
    (is (!(builtins.tryEval (mkTestLab { overrides.vpn.enable = false; }).nixosConfigurations.tmaster.config.system.build.toplevel.drvPath).success)
      "the nodes refuse a broken combination")
    (is ((k8sVars { vpn.subnet = "10.8.0.0/16"; }).vpn.errors
      == [ "vpn.subnet must be a /24 like \"10.0.100.0/24\", got \"10.8.0.0/16\"" ])
      "a VPN subnet that isn't a /24 is reported")
    (is ((k8sVars { vpn.subnet = "10.8.0.0/24"; }).vpn.errors
      == [ "wireguardUsers.alice.ip (10.0.100.2) isn't in vpn.subnet 10.8.0.0/24"
           "wireguardUsers.bob.ip (10.0.100.3) isn't in vpn.subnet 10.8.0.0/24" ])
      "VPN users outside the subnet are reported")
    (is (!(builtins.tryEval (mkTestLab { overrides.vpn.subnet = "10.8.0.0/24"; }).nixidyEnv.environmentPackage.drvPath).success)
      "the render refuses VPN users outside the subnet")
    (is ((k8sVars { backups = { enable = true; target = "ftp://nope"; }; }).backups.errors
      == [ "backups.target must look like s3://<bucket>@<region>/<path> or nfs://<host>:/<path>, got \"ftp://nope\"" ])
      "an unknown backup target is reported")
    (is ((k8sVars { backups = { enable = true; offsite.enable = true; }; }).backups.errors
      == [ "backups.offsite needs an nfs:// backups.target and an s3://<bucket>@<region>/<path> offsite.target" ])
      "an off-site copy without an NFS target is reported")
    (is ((k8sVars variants.backups-nfs-offsite.overrides).backups.errors == [ ]) "a valid NFS + off-site setup has no errors")
    (is (!(builtins.tryEval (mkTestLab { overrides.backups = { enable = true; target = "ftp://nope"; }; })
      .nixidyEnv.environmentPackage.drvPath).success) "the render refuses an invalid backup target")
  ];

  # NixOS VM test: the real master boots, runs k3s, pushes secrets, installs
  # Argo CD and runs an app (tests/vm/cluster.nix).
  # The starter repo (template/): its flake, made by mkFlake, renders as is;
  # and with nodes, users and secrets filled in, its nodes evaluate.
  template-render = (mkFlake { src = ../template; }).checks.x86_64-linux.manifests;
  # nixlab's own update tool (shellchecked when built).
  update-library = (mkTools { vars = templateVars; mode = "library"; }).update;
  # Your own secrets (mkFlake's extraSecrets) reach the k8s-secrets unit.
  extra-secrets = expect "extra-secrets" [
    (is (lib.hasInfix "myapp-credentials" ((mkFlake {
      src = ../template;
      vars = baseVars;
      secretsFile = builtins.toFile "secrets.yaml" (builtins.readFile testSecrets + "myapp_api_key: test\n");
      hardwareConfig = _: ../template/hosts/example/hardware-configuration.nix;
      extraSecrets = [{ namespace = "myapp"; secretName = "myapp-credentials"; secretKey = "api-key"; sopsSecretName = "myapp_api_key"; }];
    }).nixosConfigurations.tmaster.config.systemd.services.k8s-secrets.script)) "extraSecrets are pushed")
  ];

  template-node = (mkFlake {
    src = ../template;
    vars = baseVars;
    secretsFile = testSecrets;
    hardwareConfig = _: ../template/hosts/example/hardware-configuration.nix;
  }).checks.x86_64-linux.node-tmaster;

  # The `nix run` helpers, for real, in the build sandbox (tests/tools.nix).
  tools = import ./tools.nix { inherit pkgs tools testLib; };


  vm-cluster = import ./vm/cluster.nix { inherit pkgs mkTestLab testLib; };
  # NixOS VM test: every layer off; k3s alone deploys an app (tests/vm/minimal.nix).
  vm-minimal = import ./vm/minimal.nix { inherit pkgs mkTestLab testLib allLayersOff; };
  # NixOS VM test: monitoring on the real master, alerts delivered to a
  # stand-in webhook (tests/vm/monitoring.nix).
  vm-monitoring = import ./vm/monitoring.nix { inherit pkgs mkTestLab testLib; };
  vm-monitoring-full = import ./vm/monitoring.nix { inherit pkgs mkTestLab testLib; flavor = "full"; };

  # The monitoring alerts (nixlab's, and the light flavor's essentials): valid
  # PromQL, and promtool unit tests (synthetic metrics in, expected alerts out).
  monitoring-rules = pkgs.runCommand "monitoring-rules" {
    nativeBuildInputs = [ pkgs.prometheus.cli ];
    rules = builtins.toJSON (import ../system/k8s/services/core/monitoring-rules.nix);
    tests = builtins.toJSON (import ../system/k8s/services/core/monitoring-rules-test.nix);
    essentialRules = builtins.toJSON (import ../system/k8s/services/core/monitoring-rules-essential.nix);
    essentialTests = builtins.toJSON (import ../system/k8s/services/core/monitoring-rules-essential-test.nix);
    passAsFile = [ "rules" "tests" "essentialRules" "essentialTests" ];
  } ''
    mkdir nixlab essential
    cp "$rulesPath" nixlab/rules.yaml; cp "$testsPath" nixlab/tests.yaml
    cp "$essentialRulesPath" essential/rules.yaml; cp "$essentialTestsPath" essential/tests.yaml
    for d in nixlab essential; do
      promtool check rules $d/rules.yaml
      (cd $d && promtool test rules tests.yaml)
    done
    touch $out
  '';
}
