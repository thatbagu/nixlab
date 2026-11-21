# nix run .#rekey, for real (age, sops, git) in the build sandbox, with an
# ssh stub standing in for the nodes (each one's /persist is a directory
# here): both keys work in between, the old one goes only once pushed.
{ pkgs, testLib, tools }:

let
  K = "$HOME/.config/sops/age/keys.txt";
  ssh = pkgs.writeShellScriptBin "fake-ssh" ''
    host=''${*: -2:1}; host=''${host#*@}; cmd=''${*: -1}
    cmd=''${cmd#sudo }; cmd=''${cmd//\/persist/$NODES/$host/persist}
    exec bash -c "$cmd"
  '';
  systemctl = pkgs.writeShellScriptBin "systemctl" ''echo "$*" >> "$NODES/systemctl.log"'';
  keysIn = f: "grep -c AGE-SECRET-KEY ${f}";
in
testLib.mkSandboxTest {
  name = "rekey";
  runtimeInputs = [ tools.init tools.rekey ssh systemctl ] ++ (with pkgs; [ sops git gnugrep ]);
  setup = ''
    cp -r ${../template} repo && chmod -R u+w repo && cd repo
    printf 'vpn.example.org\npw-test-1\npw-test-1\ncf-token\nme@example.org\n' | nixlab-init >/dev/null
    export NIXLAB_SSH=fake-ssh NODES=$PWD/../nodes
    for n in tmaster.local tworker.local; do install -D -m 400 ${K} $NODES/$n/persist/etc/sops-nix/keys.txt; done
    cp ${K} ../old.key
    git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm init
    git init -q --bare ../remote.git && git remote add origin ../remote.git && git push -q origin HEAD:main
  '';
  steps = [
    { desc = "dry run"; succeed = "nixlab-rekey --dry-run | grep -c 'Would create a new age key' >/dev/null"; }
    { desc = "rekey runs"; succeed = "nixlab-rekey >out 2>&1 || { cat out >&2; false; }"; }
    { desc = "both keys on the workstation"; succeed = "[ $(${keysIn K}) = 2 ]"; }
    { desc = "both keys on every node"; succeed = "for n in tmaster.local tworker.local; do [ $(${keysIn "$NODES/$n/persist/etc/sops-nix/keys.txt"}) = 2 ] || exit 1; done"; }
    { desc = "the cluster's copy refreshed, from the master only";
      succeed = "[ \"$(cat $NODES/systemctl.log)\" = 'restart nixlab-age-key' ]"; }
    { desc = "secrets.yaml opens with both keys on file (the nodes' view)"; succeed = "SOPS_AGE_KEY_FILE=$NODES/tworker.local/persist/etc/sops-nix/keys.txt sops -d secrets.yaml >/dev/null"; }
    # (HOME: sops would also try ~/.config/sops/age/keys.txt.)
    { desc = "but not with the old key alone"; fail = "HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent SOPS_AGE_KEY_FILE=../old.key sops -d secrets.yaml >/dev/null 2>&1"; }
    { desc = "a second rekey before --finish is refused"; fail = "nixlab-rekey >/dev/null 2>&1"; }
    { desc = "--finish refuses before the commit"; succeed = "! nixlab-rekey --finish 2>err && grep -c 'Commit and push' err >/dev/null"; }
    { desc = "--finish refuses before the push";
      succeed = "git commit -qam rekey && ! nixlab-rekey --finish 2>err && grep -c 'Push first' err >/dev/null"; }
    { desc = "--finish, once pushed"; succeed = "git push -q origin HEAD:main && git fetch -q origin && nixlab-rekey --finish >/dev/null"; }
    { desc = "one key left everywhere"; succeed = "[ $(${keysIn K}) = 1 ] && for n in tmaster.local tworker.local; do [ $(${keysIn "$NODES/$n/persist/etc/sops-nix/keys.txt"}) = 1 ] || exit 1; done"; }
    { desc = "and it opens secrets.yaml"; succeed = "sops -d secrets.yaml >/dev/null && SOPS_AGE_KEY_FILE=$NODES/tmaster.local/persist/etc/sops-nix/keys.txt sops -d secrets.yaml >/dev/null"; }
    { desc = "the old key is set aside, not lost"; succeed = "diff <(grep AGE-SECRET-KEY ../old.key) <(grep AGE-SECRET-KEY ${K}.retired-*)"; }
    { desc = "--finish again: nothing to do"; succeed = "nixlab-rekey --finish | grep -c 'nothing to finish' >/dev/null"; }
  ];
}
