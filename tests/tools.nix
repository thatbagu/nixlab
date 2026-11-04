# The `nix run` helpers, run for real in the build sandbox against a copy of
# the repo (throwaway $HOME, no network): init must produce working, complete,
# encrypted secrets and be idempotent; add-wg-user must store keys and print
# the right config; new-app must scaffold and refuse bad names.
{ pkgs, tools, testLib }:

let
  inherit (pkgs) lib;
  decrypt = "SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt sops -d system/sops/secrets.yaml";
in
testLib.mkSandboxTest {
  name = "tools";
  runtimeInputs = (lib.attrValues tools) ++ (with pkgs; [ sops git ]);
  setup = ''
    cp -r ${../.} repo && chmod -R u+w repo && cd repo
    rm -f system/sops/secrets.yaml
  '';
  steps = [
    { desc = "init runs"; succeed = "printf 'vpn.example.org\\npw-test-1\\npw-test-1\\ncf-token\\nme@example.org\\n' | nixlab-init >/dev/null"; }
    { desc = "init created the age and SSH keys"; succeed = "test -f $HOME/.config/sops/age/keys.txt && test -f $HOME/.ssh/nixlab-cluster"; }
    { desc = "init wrote the age key into .sops.yaml"; fail = "grep -q age1REPLACE .sops.yaml"; }
    { desc = "init wrote clusterSshKey into vars.nix"; fail = "grep -q REPLACE_WITH_YOUR_PUBLIC_KEY vars.nix"; }
    { desc = "secrets.yaml is encrypted"; succeed = "grep -q 'ENC\\[' system/sops/secrets.yaml"; }
  ]
  # One step per secret init is supposed to write (taken from init itself).
  ++ map (key: {
    desc = "secrets.yaml has ${key}";
    succeed = "${decrypt} | grep -cE '^${key}: .' >/dev/null";
  }) tools.init.secretNames
  ++ [
    { desc = "user_password is a sha512-crypt hash"; succeed = "${decrypt} | grep -cE '^user_password: .?[$]6[$]' >/dev/null"; }
    { desc = "re-running init changes nothing";
      succeed = "before=$(sha256sum system/sops/secrets.yaml .sops.yaml vars.nix); nixlab-init </dev/null >/dev/null; [[ \"$(sha256sum system/sops/secrets.yaml .sops.yaml vars.nix)\" == \"$before\" ]]"; }

    { desc = "add-wg-user prints a config with the next free address";
      succeed = "SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt nixlab-add-wg-user carol > carol.txt && grep -q 'Address = 10.0.100.2/32' carol.txt"; }
    { desc = "add-wg-user stored carol's keys"; succeed = "${decrypt} | grep -c '^carol_wg_public_key: ' >/dev/null"; }
    { desc = "add-wg-user refuses a bad name"; fail = "nixlab-add-wg-user 'Bad Name' >/dev/null 2>&1"; }

    { desc = "new-app scaffolds an app (offline: tag kept)"; succeed = "nixlab-new-app whoami docker.io/traefik/whoami:v1.11.0 80 >/dev/null && grep -q 'port = 80;' apps/whoami.nix"; }
    { desc = "new-app refuses a bad name"; fail = "nixlab-new-app Bad_Name x 80 >/dev/null 2>&1"; }
    { desc = "new-app refuses a reserved name"; fail = "nixlab-new-app argocd x 80 >/dev/null 2>&1"; }
    { desc = "new-app refuses to overwrite an app"; fail = "nixlab-new-app whoami x 80 >/dev/null 2>&1"; }
  ];
}
