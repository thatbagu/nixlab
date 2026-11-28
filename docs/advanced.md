# Advanced

The [Guide](./getting-started.md) is enough to run a lab. This half is for when you want more: to know exactly how something works, to change what nixlab does for you, or to work on nixlab itself. Many topics have a page in each half; here they're explained in full.

## Understand it

- **[Architecture](./architecture.md):** the cluster's topology, how `vars.nix` reaches every part, disks and impermanence, the k3s and firewall setup, GitOps with Argo CD or Flux, the choices behind one interface, the security model.
- **[Platform Services](./services.md):** every service nixlab runs (MetalLB, Longhorn, Traefik, the edge proxy, Pi-hole, ExternalDNS, cert-manager, DDNS, WireGuard, Nextcloud), how each is configured and why.
- **[Managing Secrets](./secrets.md):** the two places secrets live, how the cluster decrypts its own, the leak guard, replacing the age key.
- **[Updates](./updates.md):** Renovate and the weekly update in detail, nightly and continuous node deploys, a binary cache for faster upgrades, trying a change in a local VM, nixlab's versioning.

## Configure everything

- **[Configuration Reference](./configuration.md):** every `vars.nix` field explained, with the trade-offs: high availability, Cloudflare or not, Cilium, the platform layers and a minimal cluster, the edge proxy, k3s tuning.
- **[Settings Reference](./options/README.md):** every setting with its type and default, generated from the code.
- **[Customizing nixlab](./customizing.md):** change anything nixlab does without forking it: `overrides` for its apps' Helm values and the nodes, `apps.<name>.nixos` for catalog apps, your own NixOS and app modules, chart pins, settings of your own, `mkNixlab` for repos with their own layout.

## Build with it

- **[Apps in Depth](./app-modules.md):** every option of `webApp`, `app`, `composeApp`, `chartApp` and `database`, and writing nixidy modules by hand: Helm charts, plain resources, sync waves.
- **[Installing on Difficult Hardware](./hardware-quirks.md):** how installs work underneath, machines where kexec fails, network boot, installing by hand.

## Work on nixlab

- **[Developing nixlab](./developing.md):** the repository, adding a setting, a catalog app, a platform service or a command, and the docs.
- **[Testing & CI](./testing.md):** your repo's workflows, every kind of check nixlab runs, running and writing tests.
- **[CONTRIBUTING.md](https://github.com/thatbagu/nixlab/blob/main/CONTRIBUTING.md):** pull requests and code style.
