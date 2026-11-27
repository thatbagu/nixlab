# NixOS VM test of nixlab netboot: a machine with an empty disk installs
# itself over the network. On the test LAN: a router (plain DHCP, as at
# home), a machine running `nixlab netboot` (pixiecore, answering network
# boot requests only: proxy DHCP), and a bare VM booting from the network
# (QEMU's iPXE). Checks that the bare machine gets an address from the
# router, is served nixlab's installer, and comes up with SSH open, ready
# for `nixlab install`. (The installer has no test harness inside: it's
# watched from outside.)
{ pkgs, mkTools, vars }:

let
  inherit (pkgs) lib;
  installerImage = import ../../tools/installer-image.nix { inherit pkgs lib vars; };
  netboot = (mkTools { inherit vars installerImage; }).netboot;
  qemu = pkgs.qemu_kvm;
  mac = "52:54:00:12:34:99";
in
pkgs.testers.runNixOSTest {
  name = "nixlab-netboot";
  # Machines are numbered by name: router .1, server .2.
  nodes = {
    router = {
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          dhcp-range = [ "192.168.1.100,192.168.1.150,1h" ];
          dhcp-leasefile = "/var/lib/dnsmasq/leases";
          port = 0; # DHCP only
        };
      };
      networking.firewall.allowedUDPPorts = [ 67 ];
      environment.systemPackages = [ pkgs.netcat ];
    };
    server = {
      environment.systemPackages = [ netboot pkgs.netcat ];
      # What nixlab netboot asks to have open.
      networking.firewall = { allowedUDPPorts = [ 67 69 4011 ]; allowedTCPPorts = [ 64172 ]; };
      security.sudo.wheelNeedsPassword = false;
    };
  };

  testScript = ''
    start_all()
    router.wait_for_unit("dnsmasq.service")
    server.wait_for_unit("multi-user.target")

    # nixlab netboot, from a homelab repository (it checks it's in one).
    server.succeed("mkdir -p /root/lab && touch /root/lab/flake.nix /root/lab/vars.nix")
    server.succeed("cd /root/lab && systemd-run --unit=netboot --working-directory=/root/lab ${netboot}/bin/nixlab-netboot")
    server.wait_until_succeeds("ss -ulpn | grep -c pixiecore >/dev/null", timeout=120)

    # A bare machine: no disk to boot from, network boot first.
    bare = create_machine(
        "${qemu}/bin/qemu-kvm -m 1536 -smp 2 -nographic -boot n"
        + " -netdev vde,id=lan,sock=\"$QEMU_VDE_SOCKET_1\""
        + " -device virtio-net-pci,netdev=lan,mac=${mac}"
    )
    bare.start()

    with subtest("the bare machine gets an address from the router"):
        router.wait_until_succeeds("grep -i ${mac} /var/lib/dnsmasq/leases", timeout=300)
        ip = router.succeed("grep -i ${mac} /var/lib/dnsmasq/leases | awk '{print $3}'").strip()
        print(f"bare machine: {ip}")

    with subtest("nixlab netboot serves it the installer"):
        server.wait_until_succeeds("journalctl -u netboot | grep -i '${mac}' | grep -ciE 'sent|boot' >/dev/null", timeout=300)

    with subtest("the installer comes up, SSH open, ready for nixlab install"):
        server.wait_until_succeeds(f"nc -z -w 3 {ip} 22", timeout=900)

    # The bare machine has no test harness inside to shut it down: stop its
    # QEMU directly, or the driver's cleanup waits on it (CI hung there until
    # the job's time limit, the test itself having passed).
    bare.crash()
  '';
}
