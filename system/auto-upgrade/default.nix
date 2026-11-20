{ lib, pkgs, hostname, userVars, ... }:

# Nightly self-upgrade (see vars.nix "UPDATES"): every node builds main of
# your repository (gitRepository) and switches to it, one node at a time with
# the master first. It reboots only when the kernel or initrd changed, and
# only inside the reboot window.
let
  vars = userVars;
  cfg = {
    enable = true;
    time = "03:30";
    spacingMinutes = 15;
    allowReboot = true;
    rebootWindow = { lower = "03:00"; upper = "06:00"; };
  } // (vars.autoUpgrade or { });

  # Master first, then the workers by name; each starts spacingMinutes later.
  order = lib.sort (a: b: if a.master != b.master then a.master else a.hostname < b.hostname)
    (lib.attrValues vars.nodes);
  position = lib.lists.findFirstIndex (n: n.hostname == hostname) 0 order;

  toMinutes = t: let p = map lib.toIntBase10 (lib.splitString ":" t); in builtins.elemAt p 0 * 60 + builtins.elemAt p 1;
  pad = n: lib.fixedWidthString 2 "0" (toString n);
  fromMinutes = m: "${pad (lib.mod (m / 60) 24)}:${pad (lib.mod m 60)}";
  start = fromMinutes (toMinutes cfg.time + position * cfg.spacingMinutes);

  # gitRepository is the https URL Argo CD uses; Nix fetches it as a git flake.
  flake = "git+${vars.gitRepository}?ref=main#${hostname}";
in
{
  system.autoUpgrade = lib.mkIf cfg.enable {
    enable = true;
    inherit flake;
    dates = start;
    # Fetch main again every night instead of using a cached copy.
    flags = [ "--refresh" "--print-build-logs" ];
    randomizedDelaySec = "0";
    persistent = true; # a node that was off at its time catches up at boot
    inherit (cfg) allowReboot;
    rebootWindow = cfg.rebootWindow;
  };

  # Each run's result, for monitoring's NixlabUpgradeFailed alert
  # (node-exporter reads the directory).
  systemd.services.nixos-upgrade.serviceConfig.ExecStopPost = lib.mkIf (cfg.enable && (vars.monitoring.enable or false))
    (pkgs.writeShellScript "nixlab-upgrade-metrics" ''
      d=/var/lib/nixlab-metrics; mkdir -p $d
      ok=0; [ "$SERVICE_RESULT" = success ] && ok=1
      printf 'nixlab_upgrade_success %s\nnixlab_upgrade_last_run_timestamp_seconds %s\n' $ok "$(${pkgs.coreutils}/bin/date +%s)" > $d/upgrade.prom.tmp
      mv $d/upgrade.prom.tmp $d/upgrade.prom
    '');
  environment.persistence."/persist".directories = lib.mkIf (cfg.enable && (vars.monitoring.enable or false)) [ "/var/lib/nixlab-metrics" ];
}
