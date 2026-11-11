# Power

## UPS

With a UPS (battery backup) plugged into one node by USB, nixlab shuts the whole cluster down cleanly when the battery runs low, and lets it start again when power returns. It uses [NUT](https://networkupstools.org) (Network UPS Tools), which supports most UPS brands.

What happens on a power cut:

1. The UPS switches to battery. Nothing happens yet: short cuts are ridden out.
2. When the battery gets low, the **other nodes shut down first**. The UPS node waits for them.
3. The **UPS node** shuts down last, then **tells the UPS to cut its output**.
4. When power returns, the UPS turns its outlets back on. Machines set to power on after a power loss (see below) boot, and the cluster comes back by itself.

Every node stops its pods gracefully before it goes down (up to 60 seconds; databases last), so nothing is killed mid-write. That applies to every shutdown, including the nightly upgrade reboots.

### Setting it up

1. Plug the UPS's USB cable into one node.
2. Store a password the nodes use to talk to each other about the UPS:

   ```bash
   printf '"%s"' "$(openssl rand -hex 16)" | sops set --value-stdin secrets.yaml '["ups_password"]'
   ```

3. In `vars.nix`:

   ```nix
   ups = {
     enable = true;
     node = "mymaster";        # the node with the USB cable
     shutdownAtCharge = 50;    # optional: shut down at 50% (default: when the UPS says the battery is low)
   };
   ```

4. Deploy every node (`colmena apply`, or wait for tonight's automatic upgrade).
5. Check from the UPS node: `upsc ups@localhost` lists its status (`ups.status: OL` = on line power), and `upsc -c ups@localhost` lists the other nodes watching it.

The default driver, `usbhid-ups`, covers most USB UPSes (APC, CyberPower, Eaton, ...). For others, set `driver` and `port` from [NUT's hardware list](https://networkupstools.org/stable-hcl.html).

How long the cluster needs: about two minutes for the other nodes and then the UPS node. The UPS's own "battery low" signal often comes later than that on old batteries, so `shutdownAtCharge` (e.g. 50) is the safer choice.

The other nodes reach the UPS node on NUT's port (3493), which only accepts your LAN (`lan.subnet`), with the password.

### Power on after a power loss

In each machine's BIOS/UEFI, set **"Restore on AC power loss"** (also called "AC back", "Power on after power failure") to **Power On**. Without it, the machines stay off when power returns. Machines that lack the setting can be woken with Wake-on-LAN instead (below).

## Wake-on-LAN

Wake-on-LAN starts a powered-off machine with a network packet. For each node that supports it, add its network interface and MAC address (`ip link` on the node):

```nix
nodes.worker1 = {
  # ...
  wakeOnLan = { interface = "enp1s0"; mac = "aa:bb:cc:dd:ee:ff"; };
};
```

Then:

- the node's network card keeps listening for the packet while off (also enable Wake-on-LAN in its BIOS/UEFI);
- **the masters wake every such node when they boot**: after a power cut, only the master needs "Restore on AC power loss";
- from your laptop on the same network: `nix run .#wake -- worker1` (or `--all`).
