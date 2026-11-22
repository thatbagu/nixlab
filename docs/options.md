# Settings reference

Every setting of `vars.nix`, with its type and default. Generated from
`system/vars/options.nix` (do not edit by hand). Settings not listed here
are explained in [Configuration](./configuration.md).

### autoUpgrade

Nightly upgrades of the nodes from gitRepository (docs: Updates)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### autoUpgrade\.enable



Upgrade every night\.



*Type:*
boolean



*Default:*

```nix
true
```



### backups



Backups of the volumes (docs: Backups)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### backups\.enable



Back up every Longhorn volume\.



*Type:*
boolean



*Default:*

```nix
false
```



### certManager



cert-manager: TLS certificates\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### certManager\.enable



Issue certificates (Let’s Encrypt with Cloudflare, otherwise an internal CA)\.



*Type:*
boolean



*Default:*

```nix
true
```



### cloudflare



Cloudflare: Let’s Encrypt certificates, public DNS records and DDNS\. Off: an internal certificate authority\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### cloudflare\.enable



Use Cloudflare (needs cloudflare_token in the secrets)\.



*Type:*
boolean



*Default:*

```nix
true
```



### clusterSshKey



The SSH public key that may log in to every node\.



*Type:*
string



### diskEncryption



Disk encryption settings (docs: Encryption at Rest)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### domain



Your domain: apps are at https://\<app>\.\<domain>\. With Cloudflare, a domain it manages\.



*Type:*
string



### edge



The edge proxy: HAProxy in front of the gateway, sharing port 443 by TLS server name and forwarding TCP ports\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### edge\.enable



Run the edge proxy\.



*Type:*
boolean



*Default:*

```nix
false
```



### gitRepository



This repository’s URL: CI renders the manifests into renderedBranch, which the cluster syncs from\.



*Type:*
string



### gitops



How the manifests reach the cluster\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### gitops\.enable



A GitOps controller deploys from the rendered branch\. Off: k3s applies nixlab’s manifests itself\.



*Type:*
boolean



*Default:*

```nix
profile != "single"
```



### gitops\.engine



The GitOps controller: Argo CD (with its web UI) or Flux (lighter, no UI)\.



*Type:*
one of “argocd”, “flux”



*Default:*

```nix
"argocd"
```



### ingress



The gateway (Traefik, Gateway API): https://\<app>\.\<domain>\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### ingress\.enable



Route apps through the gateway\.



*Type:*
boolean



*Default:*

```nix
true
```



### k3s



k3s tuning (docs: Configuration, k3s)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### k3s\.stableNodePasswords



Reinstalled workers rejoin with the same node password (new clusters only)\.



*Type:*
boolean



*Default:*

```nix
false
```



### lan



Your home network\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### lan\.subnet



The LAN, e\.g\. for the VPN’s “family” group\.



*Type:*
string



*Default:*

```nix
"192.168.1.0/24"
```



### longhorn



Longhorn: volumes replicated across nodes\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### longhorn\.enable



Off: k3s’ local-path storage (a volume lives on one node)\.



*Type:*
boolean



*Default:*

```nix
profile != "single"
```



### metallb



MetalLB: fixed LAN addresses for services\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### metallb\.enable



Off: k3s’ own load balancer, on the nodes’ addresses\.



*Type:*
boolean



*Default:*

```nix
profile != "single"
```



### metallbPool



MetalLB’s address pool: in your LAN, outside your DHCP range\.



*Type:*
string



*Default:*

```nix
""
```



### monitoring



Prometheus, Alertmanager and (full flavor) Grafana (docs: Monitoring)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### monitoring\.enable



Run monitoring\.



*Type:*
boolean



*Default:*

```nix
false
```



### monitoring\.flavor



“light” (Prometheus and Alertmanager, ~0\.5 GB RAM) or “full” (adds the operator and Grafana, ~1\.5 GB)\.



*Type:*
one of “light”, “full”



*Default:*

```nix
"light"
```



### nas



File shares on one node’s disks (docs: NAS)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### nas\.enable



Run the NAS\.



*Type:*
boolean



*Default:*

```nix
false
```



### nextcloud



Nextcloud (VPN-only): files, calendar and contacts\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### nextcloud\.enable



Run Nextcloud\.



*Type:*
boolean



*Default:*

```nix
true
```



### nginxIp



The gateway’s address (from the MetalLB pool): every app’s HTTPS\.



*Type:*
null or string



*Default:*

```nix
null
```



### nodes



The machines, each one a node: one machine with profile = “single”, otherwise masters and workers\.



*Type:*
attribute set of (open submodule of attribute set of anything)



*Default:*

```nix
{ }
```



### nodes\.\<name>\.address



A fixed IP (DHCP reservation): deploys and joins without mDNS\. Needed with profile = “single”\.



*Type:*
null or string



*Default:*

```nix
null
```



### nodes\.\<name>\.disk



The disk nixlab installs on (erased), e\.g\. /dev/nvme0n1\.



*Type:*
string



### nodes\.\<name>\.encrypt



Encrypt the disk, unlocked by the TPM (docs: Encryption at Rest)\. Only at install\.



*Type:*
boolean



*Default:*

```nix
false
```



### nodes\.\<name>\.hostname



The node’s hostname: hosts/\<hostname>/hardware-configuration\.nix\.



*Type:*
string



### nodes\.\<name>\.master



Runs the control plane (k3s server and etcd)\. One master, or three for high availability\.



*Type:*
boolean



*Default:*

```nix
false
```



### nodes\.\<name>\.system



The node’s platform (aarch64-linux for a Raspberry Pi 4/5)\.



*Type:*
one of “x86_64-linux”, “aarch64-linux”



*Default:*

```nix
"x86_64-linux"
```



### nodes\.\<name>\.tags



Colmena tags, for deploying to a group of nodes\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



### pihole



Pi-hole: LAN DNS with ad blocking\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### pihole\.enable



Run Pi-hole (off: VPN clients use upstreamDns)\.



*Type:*
boolean



*Default:*

```nix
true
```



### piholeIp



Pi-hole’s address (from the MetalLB pool)\.



*Type:*
null or string



*Default:*

```nix
null
```



### profile



“cluster” (several machines) or “single” (everything on one machine: no Longhorn, MetalLB or Argo CD by default)\.



*Type:*
one of “cluster”, “single”



*Default:*

```nix
"cluster"
```



### renderedBranch



The branch the rendered manifests are committed to\.



*Type:*
string



*Default:*

```nix
"k8s-rendered"
```



### signalProxy



A Signal TLS proxy at signal\.\<domain> (needs Cloudflare)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### signalProxy\.enable



Run the Signal proxy\.



*Type:*
boolean



*Default:*

```nix
true
```



### sso



Single sign-on (OIDC) at https://auth\.\<domain>, VPN-only (docs: SSO)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### sso\.enable



Run single sign-on\.



*Type:*
boolean



*Default:*

```nix
false
```



### tailscale



Remote access through Tailscale (docs: Remote Access)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### tailscale\.enable



Join the tailnet\.



*Type:*
boolean



*Default:*

```nix
false
```



### telegramProxy



A Telegram proxy on port 443, disguised as HTTPS\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### telegramProxy\.enable



Run the Telegram proxy\.



*Type:*
boolean



*Default:*

```nix
false
```



### timezone



Every node’s timezone (timedatectl list-timezones)\.



*Type:*
string



*Default:*

```nix
"UTC"
```



### ups



A UPS on one node: clean shutdown on a power cut (docs: Power)\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### ups\.enable



Watch the UPS\.



*Type:*
boolean



*Default:*

```nix
false
```



### upstreamDns



The DNS server behind Pi-hole, usually your router\.



*Type:*
string



*Default:*

```nix
"192.168.1.1"
```



### username



Your Linux user on every node\.



*Type:*
string



### vpn



The WireGuard VPN\.



*Type:*
open submodule of attribute set of anything



*Default:*

```nix
{ }
```



### vpn\.enable



Run the VPN\.



*Type:*
boolean



*Default:*

```nix
true
```



### vpn\.subnet



The VPN’s own addresses, a /24: the server is \.1, users get \.2 to \.254\.



*Type:*
string



*Default:*

```nix
"10.0.100.0/24"
```



### wireguardIp



The VPN’s address (from the MetalLB pool)\.



*Type:*
null or string



*Default:*

```nix
null
```



### wireguardUsers



VPN users: ip, group, publicKeySecret, allowedIPs, enabled (docs: WireGuard)\.



*Type:*
attribute set of attribute set of anything



*Default:*

```nix
{ }
```


