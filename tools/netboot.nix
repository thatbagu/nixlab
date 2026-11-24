# nixlab netboot: install new machines without a USB stick. Serves nixlab's
# installer over the network (PXE) from this machine: set the new machine to
# boot from the network, and it comes up as nixlab-installer, reachable over
# SSH with the cluster key (at its DHCP address, or nixlab-installer.local).
# Then: nixlab install <node> root@<its IP> (or add-node).
# It answers only network boot requests (proxy DHCP), next to your router's
# DHCP, which keeps handing out addresses. Needs root (sudo) and, on this
# machine's firewall, UDP 67, 69, 4011 and TCP 64172 open. Ctrl-C stops it.
{ pkgs, lib, mkTool, installerImage, ... }:

mkTool {
  name = "netboot";
  runtimeInputs = with pkgs; [ pixiecore coreutils ];
  text = ''
    img=${installerImage}
    echo "Serving nixlab's installer over the network (Ctrl-C stops)."
    echo "Boot the new machine from the network; then: nixlab install <node> root@<its IP>"
    # nixlab.keep: the installer waits for the install instead of rebooting
    # after 15 minutes (installer-image.nix).
    exec sudo "$(command -v pixiecore)" boot "$img/bzImage" "$img/initrd" \
      --cmdline "$(cat "$img/cmdline") nixlab.keep" \
      --dhcp-no-bind --port 64172 --status-port 64173 "$@"
  '';
}
