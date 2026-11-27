# NixOS VM test of logging in to apps (webApp auth = true): the gateway with
# the internal CA, oauth2-proxy at login.<domain> (GitHub), an app behind the
# login and one without. The VM has no internet, so nobody logs in; checks
# that the open app answers, that the protected one sends a visitor without
# a session to GitHub's login (with the callback at login.<domain>), and
# that the login itself answers.
{ pkgs, mkTestLab, testLib, overrides, extraAppModules }:

let
  inherit (pkgs) lib;
  images = (import ./images.nix { inherit pkgs; }).vm-auth;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides extraAppModules; };
  k = "k3s kubectl";
  ip = "192.168.1.193";
  domain = "yourdomain.example.com";
  listener = host: "https-${lib.replaceStrings [ "." ] [ "-" ] host}";
  curl = host: extra: "curl -sS --max-time 10 --cacert /tmp/ca.crt --resolve ${host}:443:${ip} ${extra} https://${host}";
in
testLib.mkVmTest {
  name = "nixlab-auth";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";
  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
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
    networking.firewall.allowedTCPPorts = [ 7946 ];
    networking.firewall.allowedUDPPorts = [ 7946 ];
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    modules.k8s.stripImageDigests = true;
    environment.systemPackages = [ pkgs.curl ];
  };

  subtests = [
    {
      name = "the gateway, the login and both apps come up";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; timeout = 900; }
        { waitUntil = "${k} -n gateway-system rollout status deploy/traefik --timeout=10s"; timeout = 600; }
        { waitUntil = "${k} -n gateway-system wait --for=condition=Ready certificate/${listener "private.${domain}"} certificate/${listener "public.${domain}"} certificate/${listener "login.${domain}"} --timeout=10s"; timeout = 900; }
        { waitUntil = "${k} -n auth rollout status deploy/oauth2-proxy --timeout=10s"; timeout = 600; }
        { waitUntil = "${k} -n private rollout status deploy/private --timeout=10s && ${k} -n public rollout status deploy/public --timeout=10s"; timeout = 600; }
        { succeed = "${k} -n gateway-system get secret ${listener "public.${domain}"} -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/ca.crt"; }
      ];
    }
    {
      name = "the protected app needs a login; the open one doesn't";
      steps = [
        { desc = "the open app answers";
          waitUntil = "${curl "public.${domain}" ""}/ | grep -c '^Hostname:' >/dev/null"; timeout = 300; }
        { desc = "without a session, the protected app sends you to GitHub, back to login.<domain>";
          waitUntil = "r=$(${curl "private.${domain}" "-o /dev/null -w '%{http_code} %{redirect_url}'"}/); echo \"$r\" >&2; case \"$r\" in 302\\ https://github.com/login/oauth/authorize*redirect_uri=https%3A%2F%2Flogin.${domain}%2Foauth2%2Fcallback*) ;; *) exit 1 ;; esac"; timeout = 300; }
        { desc = "the login itself answers";
          succeed = "${curl "login.${domain}" ""}/ping | grep -c OK >/dev/null"; }
      ];
    }
  ];

  onFailure = [ "${k} -n auth logs deploy/oauth2-proxy --tail=20; ${k} -n private get middleware,httproute -o yaml | head -60; ${k} -n gateway-system logs deploy/traefik --tail=20" ];
}
