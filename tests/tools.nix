# The `nix run` helpers, run for real in the build sandbox against a copy of
# the repo (throwaway $HOME, no network): init must produce working, complete,
# encrypted secrets and be idempotent; add-wg-user must store keys and print
# the right config; new-app must scaffold and refuse bad names.
{ pkgs, tools, testLib }:

let
  inherit (pkgs) lib;
  decrypt = "SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt sops -d secrets.yaml";
in
testLib.mkSandboxTest {
  name = "tools";
  runtimeInputs = (lib.attrValues tools) ++ (with pkgs; [ sops git ]);
  setup = ''
    # A homelab repo, as `nix flake init -t nixlab` creates it.
    cp -r ${../template} repo && chmod -R u+w repo && cd repo
  '';
  steps = [
    { desc = "init runs"; succeed = "printf 'vpn.example.org\\npw-test-1\\npw-test-1\\ncf-token\\nme@example.org\\n' | nixlab-init >/dev/null"; }
    { desc = "init created the age and SSH keys"; succeed = "test -f $HOME/.config/sops/age/keys.txt && test -f $HOME/.ssh/nixlab-cluster"; }
    { desc = "init wrote the age key into .sops.yaml"; fail = "grep -q age1REPLACE .sops.yaml"; }
    { desc = "init wrote clusterSshKey into vars.nix"; fail = "grep -q REPLACE_WITH_YOUR_PUBLIC_KEY vars.nix"; }
    { desc = "secrets.yaml is encrypted"; succeed = "grep -q 'ENC\\[' secrets.yaml"; }
  ]
  # One step per secret init is supposed to write (taken from init itself).
  ++ map (key: {
    desc = "secrets.yaml has ${key}";
    succeed = "${decrypt} | grep -cE '^${key}: .' >/dev/null";
  }) tools.init.secretNames
  ++ [
    { desc = "user_password is a sha512-crypt hash"; succeed = "${decrypt} | grep -cE '^user_password: .?[$]6[$]' >/dev/null"; }
    { desc = "re-running init changes nothing";
      succeed = "before=$(sha256sum secrets.yaml .sops.yaml vars.nix); nixlab-init </dev/null >/dev/null; [[ \"$(sha256sum secrets.yaml .sops.yaml vars.nix)\" == \"$before\" ]]"; }

    { desc = "add-wg-user prints a config with the next free address";
      succeed = "SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt nixlab-add-wg-user carol > carol.txt && grep -q 'Address = 10.0.100.2/32' carol.txt"; }
    { desc = "add-wg-user stored carol's keys"; succeed = "${decrypt} | grep -c '^carol_wg_public_key: ' >/dev/null"; }
    { desc = "add-wg-user refuses a bad name"; fail = "nixlab-add-wg-user 'Bad Name' >/dev/null 2>&1"; }

    { desc = "new-app scaffolds an app (offline: tag kept)"; succeed = "nixlab-new-app whoami docker.io/traefik/whoami:v1.11.0 80 >/dev/null && grep -q 'port = 80;' apps/whoami.nix"; }
    { desc = "new-app refuses a bad name"; fail = "nixlab-new-app Bad_Name x 80 >/dev/null 2>&1"; }
    { desc = "new-app refuses a reserved name"; fail = "nixlab-new-app argocd x 80 >/dev/null 2>&1"; }
    { desc = "new-app refuses to overwrite an app"; fail = "nixlab-new-app whoami x 80 >/dev/null 2>&1"; }

    # The update tool's version picking (offline, versions given on stdin).
    { desc = "update: newest chart version in the same major, pre-releases ignored";
      succeed = "[ \"$(printf '1.2.0\\n1.10.0\\n2.0.0\\n1.11.0-rc.1\\n' | nixlab-update _pick-version 1.2.0 same)\" = 1.10.0 ]"; }
    { desc = "update: a new major version";
      succeed = "[ \"$(printf '1.2.0\\n1.10.0\\n2.0.0\\n' | nixlab-update _pick-version 1.2.0 any)\" = 2.0.0 ]"; }
    { desc = "update: v-prefixed versions, no newer major";
      succeed = "[ \"$(printf 'v1.20.2\\nv1.21.3\\nv2.0.0-alpha.1\\n' | nixlab-update _pick-version v1.20.2 same)\" = v1.21.3 ] && [ -z \"$(printf 'v1.21.3\\n' | nixlab-update _pick-version v1.20.2 any)\" ]"; }
    { desc = "update: up to date prints nothing";
      succeed = "[ -z \"$(printf '1.2.0\\n1.1.0\\n' | nixlab-update _pick-version 1.2.0 same)\" ]"; }
    { desc = "update: a newer image tag of the same shape";
      succeed = "[ \"$(printf '17.11-alpine\\n17.12-alpine\\n18.6-alpine\\n18.6\\n18-alpine\\nlatest\\n' | nixlab-update _newer-tag 17.11-alpine)\" = 18.6-alpine ] && [ \"$(printf 'v3.14.0-alpine\\nv3.14.0\\n3.15.0-alpine\\n' | nixlab-update _newer-tag v3.13.3-alpine)\" = v3.14.0-alpine ]"; }
    # Landing: each update is cherry-picked onto main; images.json conflicts
    # are fine (regenerated afterwards), any other conflict skips the update.
    { desc = "update: landing cherry-picks updates, a conflicting one is skipped cleanly";
      succeed = lib.concatStringsSep " && " [
        "git init -q land && cd land && git config user.email t@t && git config user.name t"
        "mkdir -p tests/vm && echo 1 > tests/vm/images.json && echo 1 > a && echo 1 > b && touch flake.nix vars.nix && git add -A && git commit -qm base"
        "git checkout -qb one && echo 2 > tests/vm/images.json && echo 2 > a && git commit -qam one"
        "base=$(git rev-list --max-parents=0 HEAD) && git checkout -qb two $base && echo 3 > tests/vm/images.json && echo 2 > b && git commit -qam two"
        "git checkout -qb three $base && echo 9 > a && git commit -qam three"
        "git checkout -qb landing $base && nixlab-update _cherry-pick one && nixlab-update _cherry-pick two"
        "[ \"$(cat a b)\" = \"$(printf '2\\n2')\" ]"
        "! nixlab-update _cherry-pick three && git diff --quiet && git diff --cached --quiet && [ \"$(cat a)\" = 2 ]"
        "[ \"$(git rev-list --count HEAD)\" = 3 ]"
      ];
    }

    { desc = "wake: lists the nodes it can wake when called without one"; succeed = "nixlab-wake 2>&1 | grep -c 'usage' >/dev/null; [ \"$(nixlab-wake >/dev/null 2>&1; echo $?)\" = 2 ]"; }
    { desc = "wake: refuses a node without wakeOnLan"; fail = "nixlab-wake nosuchnode >/dev/null 2>&1"; }
  ];
}
