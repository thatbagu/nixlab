# Platform layers and GitOps

The optional layers of the platform (all on by default) and how manifests reach the cluster. All of these go in `vars.nix`.

<!-- Generated from system/vars/options.nix (nix build .#options-doc): don't edit by hand. -->

- **`gitRepository`**: This repository's URL: CI renders the manifests into renderedBranch, which the cluster syncs from.
  <br>*string*
- **`renderedBranch`**: The branch the rendered manifests are committed to.
  <br>*string*, default `"k8s-rendered"`

## `gitops`

How the manifests reach the cluster. More in the [guide](../architecture.md#kubernetes-deployment-gitops), including settings not listed here.

- **`gitops.enable`**: A GitOps controller deploys from the rendered branch. Off: k3s applies nixlab's manifests itself.
  <br>*boolean*, default `profile != "single"`
- **`gitops.engine`**: The GitOps controller: Argo CD (with its web UI) or Flux (lighter, no UI).
  <br>*one of "argocd", "flux"*, default `"argocd"`


## `metallb`

MetalLB: fixed LAN addresses for services.

- **`metallb.enable`**: Off: k3s' own load balancer, on the nodes' addresses.
  <br>*boolean*, default `profile != "single"`


## `longhorn`

Longhorn: volumes replicated across nodes.

- **`longhorn.enable`**: Off: k3s' local-path storage (a volume lives on one node).
  <br>*boolean*, default `profile != "single"`


## `ingress`

The gateway (Gateway API): https://&lt;app&gt;.&lt;domain&gt;.

- **`ingress.enable`**: Route apps through the gateway.
  <br>*boolean*, default `true`
- **`ingress.implementation`**: What serves the Gateway API (system/k8s/ingress/).
  <br>*value "traefik" (singular enum)*, default `"traefik"`


## `certManager`

cert-manager: TLS certificates.

- **`certManager.enable`**: Issue certificates (Let's Encrypt with Cloudflare, otherwise an internal CA).
  <br>*boolean*, default `true`


## `pihole`

Pi-hole: LAN DNS with ad blocking.

- **`pihole.enable`**: Run Pi-hole (off: VPN clients use upstreamDns).
  <br>*boolean*, default `true`


