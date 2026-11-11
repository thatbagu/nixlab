# nix run .#install, without a machine to install (the VM test vm-install does
# a real one): it must refuse what it can't do, and run nixos-anywhere with the
# right arguments.
{ pkgs, testLib, install }:

testLib.mkSandboxTest {
  name = "install";
  runtimeInputs = [ install pkgs.gnugrep ];
  setup = ''
    mkdir repo && cd repo && touch flake.nix vars.nix
    mkdir -p $HOME/.config/sops/age && echo AGE-SECRET-KEY-TEST > $HOME/.config/sops/age/keys.txt
  '';
  steps = [
    { desc = "an unknown node is refused"; fail = "nixlab-install nosuchnode root@10.0.0.9 --dry-run >/dev/null 2>&1"; }
    { desc = "no age key, no install"; fail = "SOPS_AGE_KEY_FILE=/nonexistent nixlab-install tmaster root@10.0.0.9 --dry-run >/dev/null 2>&1"; }
    { desc = "a wrong confirmation cancels before anything runs";
      fail = "echo nope | nixlab-install tmaster root@10.0.0.9 >/dev/null 2>&1"; }
    { desc = "the flake is the repo (path:, so new files count) and the node";
      succeed = "nixlab-install tmaster root@10.0.0.9 --dry-run | grep -c -- \"--flake path:$PWD#tmaster\" >/dev/null"; }
    { desc = "the age key goes along, and the target is passed on";
      succeed = "nixlab-install tmaster root@10.0.0.9 --dry-run | grep -cE -- '--target-host root@10\\.0\\.0\\.9 --extra-files ' >/dev/null"; }
    { desc = "no hardware config yet: it's read from the machine";
      succeed = "nixlab-install tmaster root@10.0.0.9 --dry-run | grep -c -- '--generate-hardware-config nixos-generate-config hosts/tmaster/hardware-configuration.nix' >/dev/null"; }
    { desc = "with a hardware config, it's used as is";
      succeed = "touch hosts/tmaster/hardware-configuration.nix && ! nixlab-install tmaster root@10.0.0.9 --dry-run | grep -c -- --generate-hardware-config >/dev/null"; }
    { desc = "other options go to nixos-anywhere";
      succeed = "nixlab-install tmaster root@10.0.0.9 --dry-run -i /k --build-on remote | grep -cE -- '-i /k --build-on remote' >/dev/null"; }
  ];
}
