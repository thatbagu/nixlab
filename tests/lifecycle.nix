# The lifecycle helpers (add-node, upgrade, status, doctor), for real in the
# build sandbox against a copy of the template: no machines, so SSH is a stub
# that fails (nothing reachable) and the install a stub that records its call.
{ pkgs, testLib, tools }:

let
  failingSsh = pkgs.writeShellScriptBin "fake-ssh" "exit 255";
  # Records each command and succeeds with no output (move-app).
  recordingSsh = pkgs.writeShellScriptBin "fake-ssh" ''echo "$@" >> "$HOME/ssh.log"; cat >/dev/null'';
  appsData = pkgs.writeText "apps.json" (builtins.toJSON {
    native.kuma = { name = "kuma"; namespace = "kuma"; node = "box"; port = 3001; module = true; state = [ "/var/lib/uptime-kuma" ]; };
    kubernetes.jelly = { namespace = "media"; volumes = [ { path = "/config"; claim = "jelly-config"; } ]; };
  });
  install = pkgs.writeShellScriptBin "fake-install" ''echo "install $*" > "$HOME/install.log"'';
in
testLib.mkSandboxTest {
  name = "lifecycle";
  runtimeInputs = (with tools; [ init add-node replace-node upgrade status doctor move-app ]) ++ (with pkgs; [ sops git gnugrep nix ]);
  setup = ''
    cp -r ${../template} repo && chmod -R u+w repo && cd repo
    git init -q && git add -A
    printf 'pw-test-1\npw-test-1\n' | nixlab-init >/dev/null
    export NIXLAB_SSH=${failingSsh}/bin/fake-ssh NIXLAB_INSTALL=${install}/bin/fake-install
  '';
  steps = [
    { desc = "add-node --dry-run shows the entry and changes nothing";
      succeed = "nixlab-add-node pi root@192.168.1.31 --dry-run | grep -c 'pi = { hostname = \"pi\"; master = false; disk = \"/dev/sda\"; tags = \\[ \"homelab\" \"worker\" \\]; address = \"192.168.1.31\"; };' >/dev/null && ! grep -q 'hostname = \"pi\"' vars.nix"; }
    { desc = "add-node adds it to vars.nix, then installs it";
      succeed = "nixlab-add-node box root@192.168.1.30 --master --disk /dev/nvme0n1 --yes && grep -c 'box = { hostname = \"box\"; master = true; disk = \"/dev/nvme0n1\"; tags = \\[ \"homelab\" \"master\" \\]; address = \"192.168.1.30\"; };' vars.nix >/dev/null && grep -qx 'install box root@192.168.1.30 --yes' $HOME/install.log"; }
    { desc = "vars.nix still evaluates, with the new node"; succeed = "[ \"$(nix-instantiate --eval -E '(import ./vars.nix).nodes.box.address' 2>/dev/null)\" = '\"192.168.1.30\"' ]"; }
    { desc = "add-node refuses a bad name"; fail = "nixlab-add-node 'Bad Name' root@1.2.3.4 --dry-run >/dev/null 2>&1"; }
    { desc = "replace-node --dry-run lists the steps and changes nothing";
      succeed = ''
        nixlab-add-node w1 root@192.168.1.40 --yes >/dev/null
        nixlab-replace-node w1 w2 root@192.168.1.41 --dry-run > out.txt
        grep -c 'drain w1 (on 192.168.1.30)' out.txt >/dev/null && grep -c 'install w2 root@192.168.1.41' out.txt >/dev/null
        grep -q 'w1 = { hostname' vars.nix && ! grep -q 'w2 = { hostname' vars.nix
      ''; }
    { desc = "replace-node gives the new machine the old one's role, installs it, and forgets the old node";
      succeed = ''
        : > $HOME/ssh.log
        NIXLAB_SSH=${recordingSsh}/bin/fake-ssh nixlab-replace-node w1 w2 root@192.168.1.41 --yes --no-wait >/dev/null
        grep -c 'w2 = { hostname = "w2"; master = false; disk = "/dev/sda"; tags = \[ "homelab" "worker" \]; address = "192.168.1.41"; };' vars.nix >/dev/null
        ! grep -q 'w1 = { hostname' vars.nix
        grep -qx 'install w2 root@192.168.1.41 --yes' $HOME/install.log
        grep -c '@192.168.1.30 KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl drain w1 --ignore-daemonsets --delete-emptydir-data' $HOME/ssh.log >/dev/null
        grep -c '@192.168.1.30 KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl delete node w1' $HOME/ssh.log >/dev/null
        [ "$(nix-instantiate --eval -E '(import ./vars.nix).nodes.w2.address' 2>/dev/null)" = '"192.168.1.41"' ]
      ''; }
    { desc = "replace-node refuses an unknown node, and a new name that's taken";
      succeed = ''
        ! nixlab-replace-node nope w3 root@192.168.1.42 --dry-run >/dev/null 2>&1
        ! nixlab-replace-node w2 box root@192.168.1.42 --dry-run >/dev/null 2>&1
        ! nixlab-replace-node box w3 root@192.168.1.42 --dry-run >/dev/null 2>&1
      ''; }
    { desc = "doctor: keys and secrets are fine after init";
      succeed = "nixlab-doctor > doctor.txt 2>&1; grep -c 'age key (' doctor.txt >/dev/null && grep -c '.sops.yaml encrypts for it' doctor.txt >/dev/null && grep -c 'secrets.yaml decrypts' doctor.txt >/dev/null && ! sed -n '/^Keys/,/^Configuration/p' doctor.txt | grep -q '✗'"; }
    { desc = "doctor: the template's placeholder SSH key and example domain are flagged, with the fix";
      succeed = "grep -c 'clusterSshKey is still the template.s placeholder' doctor.txt >/dev/null && grep -c 'domain is still the template.s example' doctor.txt >/dev/null && grep -c 'fix: put your SSH public key' doctor.txt >/dev/null"; }
    { desc = "doctor: what's wrong comes with how to fix it (offline: the repo can't be reached)";
      succeed = "grep -c 'gitRepository isn.t reachable' doctor.txt >/dev/null && grep -c 'fix: push this repo there' doctor.txt >/dev/null"; }
    { desc = "move-app: Kubernetes to native copies each volume to the node, then flips the app file";
      succeed = ''
        printf '{ nixlab, ... }: nixlab.app {\n  name = "jelly"; port = 8096; image = "x";\n}\n' > apps/jelly.nix
        printf '{ nixlab, ... }: nixlab.app {\n  name = "kuma"; port = 3001; runtime = "native"; node = "box";\n}\n' > apps/kuma.nix
        export NIXLAB_APPS_DATA=${appsData}
        NIXLAB_SSH=${recordingSsh}/bin/fake-ssh nixlab-move-app jelly native --node box >/dev/null
        grep -c 'name = "jelly"; runtime = "native"; node = "box";' apps/jelly.nix >/dev/null
        grep -c 'persistentVolumeClaim.*jelly-config' $HOME/ssh.log >/dev/null
        grep -cF '@box d=/var/lib/nixlab/jelly/config; [ -d /persist ] && d=/persist/var/lib/nixlab/jelly/config; sudo mkdir -p $d && sudo tar -C $d -xpf -' $HOME/ssh.log >/dev/null
      ''; }
    { desc = "move-app: native to Kubernetes stops the service, fills a new volume, flips the app file";
      succeed = ''
        : > $HOME/ssh.log
        NIXLAB_APPS_DATA=${appsData} NIXLAB_SSH=${recordingSsh}/bin/fake-ssh nixlab-move-app kuma kubernetes >/dev/null
        grep -c 'runtime = "kubernetes";' apps/kuma.nix >/dev/null
        grep -c '@box sudo systemctl stop kuma' $HOME/ssh.log >/dev/null
        grep -c 'sudo tar -C /var/lib/uptime-kuma -cf -' $HOME/ssh.log >/dev/null
      ''; }
    { desc = "move-app: --dry-run changes nothing; a move to where it already runs is refused";
      succeed = ''
        cp apps/kuma.nix kuma.before
        NIXLAB_APPS_DATA=${appsData} NIXLAB_SSH=${failingSsh}/bin/fake-ssh nixlab-move-app jelly kubernetes --dry-run >/dev/null 2>&1 && exit 1
        NIXLAB_APPS_DATA=${appsData} NIXLAB_SSH=${failingSsh}/bin/fake-ssh nixlab-move-app kuma native --node box --dry-run | grep -c 'would:' >/dev/null
        cmp apps/kuma.nix kuma.before
      ''; }
    { desc = "init turned the leak guard on";
      succeed = "[ \"$(git config core.hooksPath)\" = .githooks ]"; }
    { desc = "the leak guard refuses a private key, an age key, an .env file and a plain Secret";
      succeed = ''
        git config user.email t@t && git config user.name t
        # The sandbox has no /usr/bin/env (real systems do).
        sed -i "1s|.*|#!$(command -v bash)|" .githooks/pre-commit
        printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n' > key.pem; git add key.pem
        ! git commit -qm leak 2>err.txt && grep -c 'a private key in plain text' err.txt >/dev/null
        git reset -q key.pem
        echo 'AGE-SECRET-KEY-1ABC' > keys.txt; git add keys.txt
        ! git commit -qm leak 2>err.txt && grep -c 'an age secret key' err.txt >/dev/null
        git reset -q keys.txt
        echo 'PASSWORD=x' > .env; git add -f .env
        ! git commit -qm leak 2>err.txt && grep -c 'an .env file' err.txt >/dev/null
        git reset -q .env
        printf 'apiVersion: v1\nkind: Secret\nstringData:\n  password: x\n' > apps/secret.yaml; git add apps/secret.yaml
        ! git commit -qm leak 2>err.txt && grep -c 'a Kubernetes Secret in plain text' err.txt >/dev/null
        git reset -q apps/secret.yaml
      ''; }
    { desc = "...and lets an ordinary commit through";
      succeed = "rm -f key.pem keys.txt .env apps/secret.yaml && echo '# note' >> vars.nix && git add vars.nix && git commit -qm ok"; }
    { desc = "doctor reports the leak guard and a clean repository";
      succeed = "nixlab-doctor > doctor2.txt 2>&1; grep -c 'no secrets in plain text in the repository' doctor2.txt >/dev/null && grep -c 'the leak guard runs on every commit' doctor2.txt >/dev/null"; }
    { desc = "status: unreachable machines are shown, not hidden"; succeed = "! nixlab-status > status.txt 2>&1; grep -cE 'No master answered|No masters in vars.nix' status.txt >/dev/null"; }
  ];
}
