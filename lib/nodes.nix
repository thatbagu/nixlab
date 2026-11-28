# Your nodes (vars.nix nodes) and the questions every part of nixlab asks
# about them: the masters, which one is which, finding a node by name, and
# its address. Pure: each takes the settings (vars) it reads.
{ lib }:

rec {
  all = vars: lib.attrValues (vars.nodes or { });

  # The masters, by hostname.
  masters = vars: lib.sort (a: b: a.hostname < b.hostname) (lib.filter (n: n.master or false) (all vars));

  # The first master by hostname: where the services of a lab without
  # Kubernetes live (the gateway, the VPN, monitoring) and where native
  # catalog apps run by default. null without masters.
  firstMaster = vars: let ms = masters vars; in if ms == [ ] then null else lib.head ms;

  # The master that starts the cluster (k3s): the one with clusterInit, else
  # the first by hostname. null without masters.
  primaryMaster = vars: let ms = masters vars; in
    if ms == [ ] then null else lib.findFirst (n: n.clusterInit or false) (lib.head ms) ms;

  # A node by hostname; null if there's none.
  byHostname = vars: hostname: lib.findFirst (n: n.hostname == hostname) null (all vars);

  # A node named in a setting (nas.node, ups.node, tailscale.routers, ...):
  # by its key in nodes or by its hostname; null if there's none.
  byRef = vars: ref:
    if ref == null then null
    else (vars.nodes or { }).${toString ref} or (byHostname vars ref);
  isNode = vars: ref: byRef vars ref != null;

  # How your machine reaches a node over SSH: its address, else its mDNS name.
  sshAddress = n: n.address or "${n.hostname}.local";

  # How a node (by hostname `self`) reaches another: itself on localhost,
  # another at its address (else its hostname).
  addressFrom = self: n: if n.hostname == self then "127.0.0.1" else n.address or n.hostname;
}
