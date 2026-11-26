# The settings of vars.nix, as typed options: what each one is, its type and
# its default. Users still write a plain attrset; mkNixlab evaluates it against
# these options, so a wrong type is reported with the option's name, unknown
# settings are pointed out, and docs/options/ is generated from here.
#
# The defaults are the ones the code falls back to (`userVars.x or default`).
# Sections accept settings not listed here (freeformType): they're documented
# in docs/configuration.md and typed here as they're migrated.
{ lib, config, ... }:

let
  single = config.profile == "single";
  inherit (lib) mkOption types literalExpression;

  enable = description: default: mkOption { type = types.bool; inherit default description; };
  # A group of settings: typed where listed, open to the rest.
  section = description: options: mkOption {
    type = types.submodule { freeformType = types.attrsOf types.anything; inherit options; };
    default = { };
    inherit description;
  };
  str = description: default: mkOption { type = types.str; inherit default description; };
  nullStr = description: mkOption { type = types.nullOr types.str; default = null; inherit description; };

  node = types.submodule {
    freeformType = types.attrsOf types.anything;
    options = {
      hostname = mkOption { type = types.str; description = "The node's hostname: hosts/<hostname>/hardware-configuration.nix."; };
      master = enable "Runs the control plane (k3s server and etcd). One master, or three for high availability." false;
      disk = mkOption { type = types.str; description = "The disk nixlab installs on (erased), e.g. /dev/nvme0n1."; };
      tags = mkOption { type = types.listOf types.str; default = [ ]; description = "Colmena tags, for deploying to a group of nodes."; };
      address = mkOption { type = types.nullOr types.str; default = null; description = "A fixed IP (DHCP reservation): deploys and joins without mDNS. Needed with profile = \"single\"."; };
      system = mkOption { type = types.enum [ "x86_64-linux" "aarch64-linux" ]; default = "x86_64-linux"; description = "The node's platform (aarch64-linux for a Raspberry Pi 4/5)."; };
      encrypt = enable "Encrypt the disk, unlocked by the TPM (docs: Encryption at Rest). Only at install." false;
    };
  };
in
{
  options = {
    username = mkOption { type = types.str; description = "Your Linux user on every node."; };
    timezone = str "Every node's timezone (timedatectl list-timezones)." "UTC";
    clusterSshKey = mkOption { type = types.str; description = "The SSH public key that may log in to every node."; };

    nodes = mkOption {
      type = types.attrsOf node;
      default = { };
      description = "The machines, each one a node: one machine with profile = \"single\", otherwise masters and workers.";
    };

    profile = mkOption {
      type = types.enum [ "cluster" "single" ];
      default = "cluster";
      description = "\"cluster\" (several machines) or \"single\" (everything on one machine: no Longhorn, MetalLB or Argo CD by default).";
    };

    domain = mkOption { type = types.str; description = "Your domain: apps are at https://<app>.<domain>. With Cloudflare, a domain it manages."; };

    cloudflare = section "Cloudflare: Let's Encrypt certificates, public DNS records and DDNS. Off: an internal certificate authority." {
      enable = enable "Use Cloudflare (needs cloudflare_token in the secrets)." true;
    };

    gitops = section "How the manifests reach the cluster." {
      enable = mkOption {
        type = types.bool;
        default = !single;
        defaultText = literalExpression ''profile != "single"'';
        description = "A GitOps controller deploys from the rendered branch. Off: k3s applies nixlab's manifests itself.";
      };
      engine = mkOption {
        type = types.enum [ "argocd" "flux" ];
        default = "argocd";
        description = "The GitOps controller: Argo CD (with its web UI) or Flux (lighter, no UI).";
      };
    };

    metallb = section "MetalLB: fixed LAN addresses for services." {
      enable = mkOption { type = types.bool; default = !single && config.network.stack != "cilium"; defaultText = literalExpression ''profile != "single" && network.stack != "cilium"''; description = "Off: k3s' own load balancer (or Cilium's, with network.stack = \"cilium\"), on the nodes' addresses."; };
    };
    longhorn = section "Longhorn: volumes replicated across nodes." {
      enable = mkOption { type = types.bool; default = !single; defaultText = literalExpression ''profile != "single"''; description = "Off: k3s' local-path storage (a volume lives on one node)."; };
    };
    ingress = section "The gateway (Gateway API): https://<app>.<domain>." {
      enable = enable "Route apps through the gateway." true;
      implementation = mkOption {
        type = types.enum [ "traefik" "cilium" ];
        default = "traefik";
        description = "What serves the Gateway API: Traefik, or Cilium's own gateway (needs network.stack = \"cilium\"; not with the edge proxy). See system/k8s/ingress/.";
      };
    };
    network = section "The pod network and how services get LAN addresses." {
      stack = mkOption {
        type = types.enum [ "flannel" "cilium" ];
        default = "flannel";
        description = "The network stack: flannel with MetalLB, or Cilium (eBPF: replaces kube-proxy, enforces network policy, gives services their addresses itself; needs the first master's address). See system/k8s/network/.";
      };
    };
    certManager = section "cert-manager: TLS certificates." {
      enable = enable "Issue certificates (Let's Encrypt with Cloudflare, otherwise an internal CA)." true;
    };
    pihole = section "Pi-hole: LAN DNS with ad blocking." {
      enable = enable "Run Pi-hole (off: VPN clients use upstreamDns)." true;
    };
    vpn = section "The WireGuard VPN." {
      enable = enable "Run the VPN." true;
      subnet = str "The VPN's own addresses, a /24: the server is .1, users get .2 to .254." "10.0.100.0/24";
    };
    wireguardUsers = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = { };
      description = "VPN users: ip, group, publicKeySecret, allowedIPs, enabled (docs: WireGuard).";
    };

    lan = section "Your home network." {
      subnet = str "The LAN, e.g. for the VPN's \"family\" group." "192.168.1.0/24";
    };
    upstreamDns = str "The DNS server behind Pi-hole, usually your router." "192.168.1.1";
    metallbPool = str "MetalLB's address pool: in your LAN, outside your DHCP range." "";
    piholeIp = nullStr "Pi-hole's address (from the MetalLB pool).";
    wireguardIp = nullStr "The VPN's address (from the MetalLB pool).";
    nginxIp = nullStr "The gateway's address (from the MetalLB pool): every app's HTTPS.";

    gitRepository = mkOption { type = types.str; description = "This repository's URL: CI renders the manifests into renderedBranch, which the cluster syncs from."; };
    renderedBranch = str "The branch the rendered manifests are committed to." "k8s-rendered";

    nextcloud = section "Nextcloud (VPN-only): files, calendar and contacts." { enable = enable "Run Nextcloud." true; };
    signalProxy = section "A Signal TLS proxy at signal.<domain> (needs Cloudflare)." { enable = enable "Run the Signal proxy." true; };
    telegramProxy = section "A Telegram proxy on port 443, disguised as HTTPS." { enable = enable "Run the Telegram proxy." false; };
    statusPage = section "A status page at status.<domain>: a monitor per app, made from your apps (docs: Adding Apps)." { enable = enable "Run the status page (Gatus)." false; };
    sso = section "Single sign-on (OIDC) at https://auth.<domain>, VPN-only (docs: SSO)." { enable = enable "Run single sign-on." false; };
    edge = section "The edge proxy: HAProxy in front of the gateway, sharing port 443 by TLS server name and forwarding TCP ports." {
      enable = enable "Run the edge proxy." false;
    };

    backups = section "Backups of the volumes (docs: Backups)." { enable = enable "Back up every Longhorn volume." false; };
    monitoring = section "Prometheus, Alertmanager and (full flavor) Grafana (docs: Monitoring)." {
      enable = enable "Run monitoring." false;
      flavor = mkOption { type = types.enum [ "light" "full" ]; default = "light"; description = "\"light\" (Prometheus and Alertmanager, ~0.5 GB RAM) or \"full\" (adds the operator and Grafana, ~1.5 GB)."; };
    };
    autoUpgrade = section "Upgrades of the nodes from gitRepository (docs: Updates)." {
      enable = enable "Upgrade the nodes from main of gitRepository." true;
      mode = mkOption {
        type = types.enum [ "nightly" "continuous" ];
        default = "nightly";
        description = "nightly: every node upgrades at night, one after another. continuous: every node deploys each new commit to main within a minute (comin), and stays on its last good system if a deploy fails.";
      };
      pollSeconds = mkOption { type = types.ints.positive; default = 60; description = "continuous: how often each node checks main for a new commit."; };
    };
    binaryCache = section "A binary cache the nodes download their upgrades from, instead of building them (docs: Updates)." {
      url = mkOption { type = types.str; default = ""; example = "https://mylab.cachix.org"; description = "The cache's URL (empty: off). CI can push the nodes' builds there (CACHIX_NODE_CACHE)."; };
      publicKey = mkOption { type = types.str; default = ""; example = "mylab.cachix.org-1:AbC...="; description = "The cache's signing key: nodes only trust what it signed."; };
    };

    nas = section "File shares on one node's disks (docs: NAS)." { enable = enable "Run the NAS." false; };
    ups = section "A UPS on one node: clean shutdown on a power cut (docs: Power)." { enable = enable "Watch the UPS." false; };
    tailscale = section "Remote access through Tailscale (docs: Remote Access)." { enable = enable "Join the tailnet." false; };
    diskEncryption = section "Disk encryption settings (docs: Encryption at Rest)." { };
    k3s = section "k3s tuning (docs: Configuration, k3s)." {
      stableNodePasswords = enable "Reinstalled workers rejoin with the same node password (new clusters only)." false;
    };
  };
}
