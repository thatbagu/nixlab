{ lib, pkgs, hostname, userVars, ... }:

# The nodes upgrade themselves from main of your repository (gitRepository;
# see vars.nix "UPDATES"):
# - nightly (the default): every node builds main and switches to it, one
#   node at a time with the master first. It reboots only when the kernel or
#   initrd changed, and only inside the reboot window.
# - continuous: comin on every node pulls main every pollSeconds and deploys
#   each new commit; a commit that fails to build or switch leaves the node on
#   its last good system, staggered (masters first, staggerSeconds apart).
#   No reboots: a new kernel waits for the next one.
let
  vars = userVars;
  cfg = {
    enable = true;
    mode = "nightly";
    pollSeconds = 60;
    staggerSeconds = 60;
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

  nightly = cfg.enable && cfg.mode == "nightly";
  continuous = cfg.enable && cfg.mode == "continuous";
  metrics = vars.monitoring.enable or false;

  # Each upgrade's result, for monitoring's NixlabUpgradeFailed alert
  # (node-exporter reads the directory). $1: 1 (worked) or 0.
  writeMetrics = ''
    d=/var/lib/nixlab-metrics; mkdir -p $d
    printf 'nixlab_upgrade_success %s\nnixlab_upgrade_last_run_timestamp_seconds %s\n' "$1" "$(${pkgs.coreutils}/bin/date +%s)" > $d/upgrade.prom.tmp
    mv $d/upgrade.prom.tmp $d/upgrade.prom
  '';
in
{
  system.autoUpgrade = lib.mkIf nightly {
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

  services.comin = lib.mkIf continuous {
    enable = true;
    # Staggered, masters first: the first node deploys at once, each next
    # one staggerSeconds later (comin confirms the deploy after the delay).
    deployConfirmer = if position == 0 || cfg.staggerSeconds == 0 then { mode = "without"; }
      else { mode = "auto"; autoconfirm_duration = position * cfg.staggerSeconds; };
    inherit hostname;
    remotes = [{
      name = "origin";
      url = vars.gitRepository;
      branches.main.name = "main";
      poller.period = cfg.pollSeconds;
    }];
    # The result of each deploy, and the commit it deployed (nix run .#status).
    postDeploymentCommand = pkgs.writeShellScript "nixlab-comin-deployed" ''
      [ "$COMIN_STATUS" = done ] || [ "$COMIN_STATUS" = failed ] || exit 0
      mkdir -p /var/lib/nixlab
      printf '%s %s\n' "$COMIN_GIT_SHA" "$COMIN_STATUS" > /var/lib/nixlab/deployed
      ${lib.optionalString metrics ''
        set -- "$([ "$COMIN_STATUS" = done ] && echo 1 || echo 0)"
        ${writeMetrics}
      ''}
    '';
  };

  systemd.services.nixos-upgrade.serviceConfig.ExecStopPost = lib.mkIf (nightly && metrics)
    (pkgs.writeShellScript "nixlab-upgrade-metrics" ''
      set -- "$([ "$SERVICE_RESULT" = success ] && echo 1 || echo 0)"
      ${writeMetrics}
    '');
  environment.persistence."/persist".directories = lib.mkIf cfg.enable (
    lib.optional metrics "/var/lib/nixlab-metrics"
    # comin's state: what it deployed, so a reboot doesn't redeploy.
    ++ lib.optionals continuous [ "/var/lib/comin" "/var/lib/nixlab" ]);
}
