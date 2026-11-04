# Tests written as Nix data. Each test is a list of steps; these functions
# turn them into what the runners execute (a NixOS VM test driver script, or a
# sandboxed build), so nobody has to write the Python or the shell by hand.
#
# A step is one of:
#   { succeed = "cmd"; }                       command must exit 0
#   { fail = "cmd"; }                          command must exit non-zero
#   { waitUntil = "cmd"; timeout = 300; }      retry until it exits 0
#   { waitForUnit = "k3s.service"; timeout = 300; }   (VM tests only)
# Commands run in bash; add `desc` to any step for a readable log line.
{ pkgs }:

let
  inherit (pkgs) lib;

  py = builtins.toJSON; # a JSON string is a valid Python string literal

  vmStep = node: step:
    let
      t = toString (step.timeout or 300);
      comment = lib.optionalString (step ? desc) "    # ${step.desc}\n";
    in
    comment + (
      if step ? succeed then "    ${node}.succeed(${py step.succeed})\n"
      else if step ? fail then "    ${node}.fail(${py step.fail})\n"
      else if step ? waitUntil then "    ${node}.wait_until_succeeds(${py step.waitUntil}, timeout=${t})\n"
      else if step ? waitForUnit then "    ${node}.wait_for_unit(${py step.waitForUnit}, timeout=${t})\n"
      else throw "unknown test step: ${builtins.toJSON step}");

  shellStep = step:
    let
      desc = step.desc or (step.succeed or step.fail or step.waitUntil);
      t = toString (step.timeout or 60);
    in
    if step ? succeed then ''
      if ( ${step.succeed} ); then pass ${lib.escapeShellArg desc}; else fail ${lib.escapeShellArg desc}; fi
    ''
    else if step ? fail then ''
      if ( ${step.fail} ); then fail ${lib.escapeShellArg desc}; else pass ${lib.escapeShellArg desc}; fi
    ''
    else if step ? waitUntil then ''
      ok=; for _ in $(seq 1 ${t}); do if ( ${step.waitUntil} ); then ok=1; break; fi; sleep 1; done
      if [[ -n "$ok" ]]; then pass ${lib.escapeShellArg desc}; else fail ${lib.escapeShellArg desc}; fi
    ''
    else throw "step not supported outside VM tests: ${builtins.toJSON step}";
in
{
  # A NixOS VM test. subtests: [ { name; steps = [ ... ]; } ].
  # The node boots first; every subtest runs in order.
  mkVmTest = { name, node, specialArgs ? { }, nodeName ? "machine", subtests }:
    pkgs.testers.runNixOSTest {
      inherit name;
      node.specialArgs = specialArgs;
      # nixlab's node config sets nixpkgs options (overlays, allowUnfree).
      node.pkgsReadOnly = false;
      nodes.${nodeName} = node;
      testScript = "${nodeName}.start()\n" + lib.concatMapStrings (st: ''
        with subtest(${py st.name}):
      '' + lib.concatMapStrings (vmStep nodeName) st.steps) subtests;
    };

  # A test that runs commands in the build sandbox (no network, a throwaway
  # $HOME). runtimeInputs: packages on PATH. setup: commands run first.
  mkSandboxTest = { name, runtimeInputs ? [ ], setup ? "", steps }:
    pkgs.runCommand "test-${name}" { nativeBuildInputs = runtimeInputs; } ''
      set -uo pipefail
      export HOME=$TMPDIR/home; mkdir -p "$HOME"
      failures=0
      pass() { printf 'PASS %s\n' "$1"; }
      fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
      ${setup}
      ${lib.concatMapStrings shellStep steps}
      if [[ $failures -gt 0 ]]; then echo "$failures step(s) failed"; exit 1; fi
      touch $out
    '';
}
