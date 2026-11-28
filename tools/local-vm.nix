# nix run .#vm: your lab's (first) master as a QEMU VM on this machine, to
# try a change before pushing it. It's the node's own configuration with:
# - a fresh, empty 8G disk for /persist on every run, so each run starts
#   clean (the root is wiped at boot as on the real node; ./nixlab-vm/ holds
#   only the VM's root image);
# - your age key, shared in read-only, so the node's secrets decrypt;
# - the node's address added inside the VM (k3s binds to it), its network
#   NAT'd through your machine: SSH on localhost:2222, the node's ports 80
#   and 443 on localhost:8080 and localhost:8443.
# Apps come from where they always do: with GitOps, the rendered branch of
# gitRepository (what's pushed); without, this repository.
{ lib, pkgs, lab, vars }:

let
  master = lib.findFirst (n: n.master or false) null (lib.attrValues vars.nodes);
  node = lab.nixosConfigurations.${master.hostname};
  vm = (node.extendModules {
    modules = [ ({ modulesPath, ... }: {
      imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];
      virtualisation = {
        memorySize = 4096;
        cores = 4;
        diskSize = 20480;
        diskImage = "./nixlab-vm/root.qcow2";
        emptyDiskImages = [ 8192 ];
        fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
        forwardPorts = [
          { from = "host"; host.port = 2222; guest.port = 22; }
          { from = "host"; host.port = 8080; guest.port = 80; }
          { from = "host"; host.port = 8443; guest.port = 443; }
        ];
        # The run script expands this when it starts the VM.
        sharedDirectories.nixlab-age = { source = "$NIXLAB_VM_AGE_DIR"; target = "/run/nixlab-age"; };
      };
      system.activationScripts = {
        nixlabVmAgeKey.text = ''
          [ -r /run/nixlab-age/keys.txt ] && install -D -m 0400 /run/nixlab-age/keys.txt /persist/etc/sops-nix/keys.txt || true
        '';
        setupSecrets.deps = [ "nixlabVmAgeKey" ];
        setupSecretsForUsers.deps = [ "nixlabVmAgeKey" ];
      };
      networking.interfaces.eth0.ipv4.addresses = lib.optional (master ? address) { address = master.address; prefixLength = 24; };
    }) ];
  }).config.system.build.vm;
in
assert lib.assertMsg (master != null) "nix run .#vm: no master in vars.nix nodes";
pkgs.writeShellApplication {
  name = "nixlab-vm";
  text = ''
    key=''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
    [[ -r "$key" ]] || { echo "No age key at $key (nixlab init makes one): the node's secrets wouldn't decrypt." >&2; exit 1; }
    mkdir -p nixlab-vm
    NIXLAB_VM_AGE_DIR=$(cd "$(dirname "$key")" && pwd)
    export NIXLAB_VM_AGE_DIR
    echo "Starting ${master.hostname} as a VM (it starts clean every run; Ctrl-A X quits)."
    echo "  ssh -p 2222 ${vars.username}@localhost     https://localhost:8443"
    exec ${vm}/bin/run-${master.hostname}-vm -nographic "$@"
  '';
}
