# nix run .#reinstall, without a node to reinstall: it must refuse what it
# can't do (the only master), and plan the right steps. The installer image is
# a stub here; the real one is tools/installer-image.nix.
{ pkgs, testLib, reinstall }:

testLib.mkSandboxTest {
  name = "reinstall";
  runtimeInputs = [ reinstall pkgs.gnugrep ];
  setup = ''
    mkdir repo && cd repo && touch flake.nix vars.nix
  '';
  steps = [
    { desc = "no node, the usage"; fail = "nixlab-reinstall >/dev/null 2>&1"; }
    { desc = "an unknown node is refused"; fail = "nixlab-reinstall nosuchnode --dry-run >/dev/null 2>&1"; }
    { desc = "an unknown option is refused"; fail = "nixlab-reinstall tworker --force >/dev/null 2>&1"; }
    { desc = "the only master is refused (it would start a new cluster)";
      succeed = "! nixlab-reinstall tmaster --dry-run 2>err && grep -c 'only master' err >/dev/null"; }
    { desc = "a worker: installer onto its disk, GRUB once, install without kexec";
      succeed = "out=$(nixlab-reinstall tworker --dry-run) && grep -c '/persist/nixlab-installer' <<<\"$out\" >/dev/null && grep -c 'one-time GRUB entry' <<<\"$out\" >/dev/null && grep -c -- '--phases disko,install,reboot' <<<\"$out\" >/dev/null"; }
    { desc = "then its old Longhorn disk is forgotten, on the master";
      succeed = "nixlab-reinstall tworker --dry-run | grep -c 'on tmaster: nixlab-longhorn-reset-node tworker' >/dev/null"; }
    { desc = "without stableNodePasswords, its k3s node password is forgotten so it can rejoin";
      succeed = "nixlab-reinstall tworker --dry-run | grep -c 'forget tworker.s k3s node password on tmaster' >/dev/null"; }
  ];
}
