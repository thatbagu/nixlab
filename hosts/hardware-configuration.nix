# 1. Add this node to vars.nix nodes:
#      mynode = { hostname = "mynode"; master = false; disk = "/dev/sda"; tags = [...]; };
# 2. Copy this file to hosts/mynode/hardware-configuration.nix
# 3. Replace the contents with the output of 'nixos-generate-config' run on the target machine
#    (the generated file is at /etc/nixos/hardware-configuration.nix)
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ]; # or kvm-amd
  boot.extraModulePackages = [ ];

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
