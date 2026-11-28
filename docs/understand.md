# Understand It

How nixlab works underneath, in full. The short version is [How It Works](./how-it-works.md).

- **[Architecture](./architecture.md):** topology, how `vars.nix` reaches every part, disks and impermanence, k3s and the firewall, GitOps, the security model.
- **[Platform Services](./services.md):** each service nixlab runs, how it's configured and why.
- **[Managing Secrets](./secrets.md):** where secrets live, how the cluster decrypts them, the leak guard, replacing the age key.
- **[Updates](./updates.md):** Renovate and the weekly update, nightly and continuous deploys, binary caches, nixlab's versions.
