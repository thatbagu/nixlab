# The `nix run .#<name>` helpers. Their logic is Nix (what to generate, IP
# allocation, templates); each becomes a small script for the parts Nix can't
# do itself: prompting, creating keys, calling sops, writing files.
#
# mode "consumer": a homelab repo made from template/ (vars.nix, secrets.yaml,
#   secrets/k8s/, apps/ at its root): init, add-wg-user, new-app, install,
#   render, update, secrets.
# mode "library": the nixlab repository itself: update (platform image
#   digests and the VM tests' images too).
# paths: where a homelab repo keeps vars.nix, secrets.yaml and hosts/, relative
#   to its root (a repo that uses mkNixlab directly can lay them out its own way).
# installerImage: what `reinstall` boots (tests pass a stub; the real one is
#   tools/installer-image.nix).
# secretsData: the config's Kubernetes Secrets ({ declared; values; } from the
#   render), built into `secrets`/`init` so they work offline.
{ pkgs, nixidyCli, vars, mode ? "consumer", paths ? { }, installerImage ? null, secretsData ? null, appsData ? null }:

let
  inherit (pkgs) lib;
  library = mode == "library";
  p = { vars = "vars.nix"; secrets = "secrets.yaml"; hosts = "hosts"; } // paths;

  # A tool that must run from the repository root (shellchecked at build time).
  mkTool = { name, runtimeInputs ? [ ], text }: pkgs.writeShellApplication {
    name = "nixlab-${name}";
    inherit runtimeInputs;
    text = (if library then ''
      if [[ ! -f flake.nix || ! -d template || ! -d system ]]; then
        echo "Run this from the root of the nixlab repository." >&2
        exit 1
      fi
    '' else ''
      if [[ ! -f flake.nix || ! -f ${p.vars} ]]; then
        echo "Run this from the root of your homelab repository (where ${p.vars} is)." >&2
        exit 1
      fi
    '') + text;
  };
  args = { inherit pkgs lib vars mkTool library secretsData; secretsPath = p.secrets; hostsDir = p.hosts; varsPath = p.vars; };

  # `nixlab help`, and the docs' CLI reference (docs/cli.md).
  cliCommands = tools: map (c: c // { package = tools.${c.name}; }) [
    { name = "init"; usage = "nixlab init";
      about = "Create your keys and the encrypted secrets.yaml";
      details = "Safe to run again: after a change to vars.nix it adds the secrets new settings need, and leaves the rest alone."; }
    { name = "doctor"; usage = "nixlab doctor";
      about = "Check your repository and the machines";
      details = "Before or after installing; says how to fix each problem. Changes nothing."; }
    { name = "install"; usage = "nixlab install <node> <target> [--yes] [--dry-run]";
      about = "Install a node over SSH, erasing its disk";
      details = "target: how to reach it, e.g. root@192.168.1.20. Other options go to nixos-anywhere."; }
    { name = "add-node"; usage = "nixlab add-node <name> <root@IP> [--master] [--disk /dev/sda] [--address IP] [--yes] [--dry-run]";
      about = "Add a machine: its entry in vars.nix, then the install";
      details = "It joins the cluster when it boots. The machine: any Linux with SSH."; }
    { name = "replace-node"; usage = "nixlab replace-node <old> <new> <root@IP> [--disk /dev/sda] [--no-wait] [--yes] [--dry-run]";
      about = "Put a new machine in place of a node (e.g. a dead one)";
      details = "Drains the old node, gives the new one its role in vars.nix, installs it, then forgets the old node and its Longhorn disk."; }
    { name = "netboot"; usage = "nixlab netboot";
      about = "Serve the installer over the network (PXE)";
      details = "Install new machines without a USB stick: they come up as nixlab-installer. Needs sudo; Ctrl-C stops it."; }
    { name = "reinstall"; usage = "nixlab reinstall <node> [--yes] [--dry-run] [--new-cluster]";
      about = "Reinstall a running node from scratch, remotely";
      details = "--new-cluster: the only master. It backs every app up, reinstalls, lets the workers join the new cluster and restores every app."; }
    { name = "unlock"; usage = "nixlab unlock <node> [--dry-run]";
      about = "Unlock an encrypted node waiting for its passphrase";
      details = "Gives its boot stage the passphrase from secrets.yaml, waits for it to boot, and enrolls its TPM again."; }
    { name = "wake"; usage = "nixlab wake <node>... | --all";
      about = "Wake nodes with Wake-on-LAN";
      details = "Needs nodes.<name>.wakeOnLan in vars.nix."; }
    { name = "upgrade"; usage = "nixlab upgrade [<node>] [--dry-run]";
      about = "Run the nightly upgrade now";
      details = "Each node builds main of your repository and switches, one at a time, masters first. Push your changes first."; }
    { name = "status"; usage = "nixlab status";
      about = "The whole lab on one screen";
      details = "Every node, the apps, certificates, backups and Longhorn's volumes, over SSH. Read-only."; }
    { name = "new-app"; usage = "nixlab new-app <name> <image> <port>";
      about = "Add an app (apps/<name>.nix)";
      details = "Writes apps/<name>.nix with the image pinned by digest. Commit and push: Argo CD deploys it."; }
    { name = "move-app"; usage = "nixlab move-app <app> native|kubernetes [--node <hostname>] [--dry-run]";
      about = "Move an app between Kubernetes and running natively, with its data";
      details = "The data is copied before the switch; then it sets runtime (and node) in the app's file: commit and push."; }
    { name = "routes"; usage = "nixlab routes [--json]";
      about = "List every app's address, where it runs, and its backups";
      details = "From your repository, offline: host, app, Kubernetes or the node it runs on, its volumes and whether they're backed up."; }
    { name = "add-wg-user"; usage = "nixlab add-wg-user <name>";
      about = "Add a VPN user and print their WireGuard config";
      details = "Stores their keys in secrets.yaml and gives them the next free address."; }
    { name = "secrets"; usage = "nixlab secrets list | sync [--yes] | set <value> [--generate] | get <value>";
      about = "The cluster's Kubernetes Secrets (secrets/k8s/)";
      details = "list: every value and where it comes from. sync: create what's missing (run it after turning something on). set/get: one value, in every Secret that carries it."; }
    { name = "rekey"; usage = "nixlab rekey [--finish] [--dry-run]";
      about = "Replace the age key that encrypts secrets.yaml";
      details = "First a new key joins the old one everywhere and secrets.yaml is encrypted for it; commit and push; then --finish removes the old key."; }
    { name = "render"; usage = "nixlab render";
      about = "Render the Kubernetes manifests into ./result";
      details = "The same render CI pushes for Argo CD."; }
    { name = "update"; usage = "nixlab update [list | apply <id>]";
      about = "Update inputs, charts and images";
      details = "One change at a time, each checked; what the weekly CI job runs."; }
  ];
in
if library then {
  update = import ./update.nix args;
  # The tests' Secrets (tests/vm/secrets/k8s/) are made with it too.
  secrets = import ./secrets.nix args;
} else let tools = {
  init = import ./init.nix (args // { secretsTool = import ./secrets.nix args; });
  new-app = import ./new-app.nix args;
  add-wg-user = import ./add-wg-user.nix args;
  install = import ./install.nix args;
  reinstall = import ./reinstall.nix (args // {
    install = import ./install.nix args;
    installerImage = if installerImage != null then installerImage
      else import ./installer-image.nix { inherit pkgs lib vars; };
  });
  update = import ./update.nix args;
  wake = import ./wake.nix args;
  unlock = import ./unlock.nix args;
  rekey = import ./rekey.nix args;
  secrets = import ./secrets.nix args;
  status = import ./status.nix args;
  upgrade = import ./upgrade.nix args;
  move-app = import ./move-app.nix args;
  routes = import ./routes.nix args;
  doctor = import ./doctor.nix args;
  add-node = import ./add-node.nix args;
  replace-node = import ./replace-node.nix args;
  netboot = import ./netboot.nix (args // {
    installerImage = if installerImage != null then installerImage
      else import ./installer-image.nix { inherit pkgs lib vars; };
  });
  render = mkTool {
    name = "render";
    runtimeInputs = [ nixidyCli ];
    text = ''
      nixidy build .#homelab "$@"
      echo "Rendered manifests: ./result (one directory per app)"
    '';
  };
};
in tools // {
  # `nixlab <command>`: these tools behind one command (system/cli.nix).
  nixlab = (import ../system/cli.nix { inherit pkgs; }).mkCli {
    where = "your homelab repository";
    commands = cliCommands tools;
  };
}
