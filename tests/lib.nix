# Tests written as Nix data. Each test is a list of steps; these functions
# turn them into what the runners execute (a NixOS VM test driver script, or a
# sandboxed build), so nobody has to write the Python or the shell by hand.
#
# A step is one of:
#   { succeed = "cmd"; }                       command must exit 0
#   { fail = "cmd"; }                          command must exit non-zero
#   { waitUntil = "cmd"; timeout = 300; }      retry until it exits 0
#   { waitForUnit = "k3s.service"; timeout = 300; }   (VM tests only)
#   { shutdown = true; on = "tmaster"; }        power a machine off (VM tests only)
#   { start = true; on = "tmaster"; }           boot it again (VM tests only)
#   { waitForShutdown = true; on = "tworker"; }
#                                              wait until it powers itself off
#   { copy = { from = "a"; path = "/x"; to = "b"; dest = "/y"; }; }
#                                              a file from one machine to
#                                              another, root-only (VM tests only)
# In VM tests with several machines, `on = "client";` runs a step on another
# one (default: the main node).
# Commands run in bash; add `desc` to any step for a readable log line.
# The VM test driver uses pipefail: never end a pipe in `grep -q` (it exits at
# the first match, the writer dies of SIGPIPE, and the match counts as a
# failure). Use `grep -c PATTERN >/dev/null`, which reads all its input.
{ pkgs }:

let
  inherit (pkgs) lib;

  py = builtins.toJSON; # a JSON string is a valid Python string literal

  # One step as Python statement lines (unindented).
  vmStep = mainNode: step:
    let
      t = toString (step.timeout or 300);
      node = step.on or mainNode;
    in
    lib.optional (step ? desc) "# ${step.desc}" ++ [
      (if step ? succeed then "${node}.succeed(${py step.succeed})"
      else if step ? fail then "${node}.fail(${py step.fail})"
      else if step ? waitUntil then "${node}.wait_until_succeeds(${py step.waitUntil}, timeout=${t})"
      else if step ? waitForUnit then "${node}.wait_for_unit(${py step.waitForUnit}, timeout=${t})"
      else if step ? shutdown then "${node}.shutdown()"
      else if step ? start then "${node}.start()"
      else if step ? waitForShutdown then "${node}.wait_for_shutdown()"
      else if step ? copy then
        let c = step.copy; in
        "${c.to}.succeed(\"install -D -m 0400 /dev/stdin ${c.dest or c.path} <<'NIXLAB_EOF'\\n\" + ${c.from}.succeed(${py "cat ${c.path}"}).strip() + \"\\nNIXLAB_EOF\")"
      else throw "unknown test step: ${builtins.toJSON step}")
    ];

  indent = n: map (l: lib.fixedWidthString n " " "" + l);
  lines = ls: lib.concatMapStrings (l: l + "\n") ls;

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
  # The node boots first; every subtest runs in order. onFailure: commands
  # whose output is printed when a step fails (logs, state), to see why; a
  # string runs on the main node, { on = "client"; cmd = "..."; } elsewhere.
  # extraNodes: more machines (e.g. a VPN client), { name = module; }.
  mkVmTest = { name, node, specialArgs ? { }, nodeName ? "machine", extraNodes ? { }, subtests, onFailure ? [ ] }:
    pkgs.testers.runNixOSTest {
      inherit name;
      node.specialArgs = specialArgs;
      # nixlab's node config sets nixpkgs options (overlays, allowUnfree).
      node.pkgsReadOnly = false;
      nodes = { ${nodeName} = node; } // extraNodes;
      testScript = lines ([ "start_all()" "try:" ]
        ++ indent 4 (lib.concatMap (st:
          [ "with subtest(${py st.name}):" ] ++ indent 4 (lib.concatMap (vmStep nodeName) st.steps)) subtests)
        ++ [ "except Exception:" ]
        ++ indent 4 (lib.concatMap (f:
          let node = if builtins.isString f then nodeName else f.on or nodeName;
              cmd = if builtins.isString f then f else f.cmd;
          in [ "print(${py "--- ${node}: ${cmd}"})" "print(${node}.execute(${py cmd})[1])" ]) onFailure
          ++ [ "raise" ]));
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
