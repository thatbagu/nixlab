# The lifecycle helpers (add-node, upgrade, status, doctor), for real in the
# build sandbox against a copy of the template: no machines, so SSH is a stub
# that fails (nothing reachable) and the install a stub that records its call.
{ pkgs, testLib, tools }:

let
  failingSsh = pkgs.writeShellScriptBin "fake-ssh" "exit 255";
  install = pkgs.writeShellScriptBin "fake-install" ''echo "install $*" > "$HOME/install.log"'';
in
testLib.mkSandboxTest {
  name = "lifecycle";
  runtimeInputs = (with tools; [ init add-node upgrade status doctor ]) ++ (with pkgs; [ sops git gnugrep nix ]);
  setup = ''
    cp -r ${../template} repo && chmod -R u+w repo && cd repo
    git init -q && git add -A
    printf 'vpn.example.org\npw-test-1\npw-test-1\ncf-token\nme@example.org\n' | nixlab-init >/dev/null
    export NIXLAB_SSH=${failingSsh}/bin/fake-ssh NIXLAB_INSTALL=${install}/bin/fake-install
  '';
  steps = [
    { desc = "add-node --dry-run shows the entry and changes nothing";
      succeed = "nixlab-add-node pi root@192.168.1.31 --dry-run | grep -c 'pi = { hostname = \"pi\"; master = false; disk = \"/dev/sda\"; tags = \\[ \"homelab\" \"worker\" \\]; address = \"192.168.1.31\"; };' >/dev/null && ! grep -q 'hostname = \"pi\"' vars.nix"; }
    { desc = "add-node adds it to vars.nix, then installs it";
      succeed = "nixlab-add-node box root@192.168.1.30 --master --disk /dev/nvme0n1 --yes && grep -c 'box = { hostname = \"box\"; master = true; disk = \"/dev/nvme0n1\"; tags = \\[ \"homelab\" \"master\" \\]; address = \"192.168.1.30\"; };' vars.nix >/dev/null && grep -qx 'install box root@192.168.1.30 --yes' $HOME/install.log"; }
    { desc = "vars.nix still evaluates, with the new node"; succeed = "[ \"$(nix-instantiate --eval -E '(import ./vars.nix).nodes.box.address' 2>/dev/null)\" = '\"192.168.1.30\"' ]"; }
    { desc = "add-node refuses a bad name"; fail = "nixlab-add-node 'Bad Name' root@1.2.3.4 --dry-run >/dev/null 2>&1"; }
    { desc = "doctor: keys and secrets are fine after init";
      succeed = "nixlab-doctor > doctor.txt 2>&1; grep -c 'age key (' doctor.txt >/dev/null && grep -c '.sops.yaml encrypts for it' doctor.txt >/dev/null && grep -c 'secrets.yaml decrypts' doctor.txt >/dev/null && ! sed -n '/^Keys/,/^Configuration/p' doctor.txt | grep -q '✗'"; }
    { desc = "doctor: what's wrong comes with how to fix it (offline: the repo can't be reached)";
      succeed = "grep -c 'gitRepository isn.t reachable' doctor.txt >/dev/null && grep -c 'fix: push this repo there' doctor.txt >/dev/null"; }
    { desc = "status: unreachable machines are shown, not hidden"; succeed = "! nixlab-status > status.txt 2>&1; grep -cE 'No master answered|No masters in vars.nix' status.txt >/dev/null"; }
  ];
}
