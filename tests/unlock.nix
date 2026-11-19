# nix run .#unlock, without a node waiting at its boot stage: it must refuse
# nodes that aren't encrypted, and plan the unlock of those that are.
{ pkgs, testLib, unlock }:

testLib.mkSandboxTest {
  name = "unlock";
  runtimeInputs = [ unlock pkgs.gnugrep ];
  setup = ''
    mkdir repo && cd repo && touch flake.nix vars.nix
  '';
  steps = [
    { desc = "no node, the usage"; fail = "nixlab-unlock >/dev/null 2>&1"; }
    { desc = "an unknown node is refused"; fail = "nixlab-unlock nosuchnode --dry-run >/dev/null 2>&1"; }
    { desc = "a node that isn't encrypted is refused";
      succeed = "! nixlab-unlock tworker --dry-run 2>err && grep -c \"isn't an encrypted node\" err >/dev/null"; }
    { desc = "an encrypted node: its boot stage on port 2222 gets the passphrase from secrets.yaml";
      succeed = "nixlab-unlock tmaster --dry-run | grep -c 'port 2222.*secrets.yaml' >/dev/null"; }
  ];
}
