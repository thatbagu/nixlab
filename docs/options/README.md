# Settings Reference

Every setting of `vars.nix`, by topic, with its type and default. Most labs
only change a few of them; [Configuration](../configuration.md) explains
how they fit together.

- [Machines and access](./machines.md): Who you are on the nodes, which machines make up the lab, and how they're kept up to date.
- [Network and DNS](./network.md): Your domain and LAN, the services' addresses, the VPN and the edge proxy.
- [Platform layers and GitOps](./platform.md): The optional layers of the platform (all on by default) and how manifests reach the cluster.
- [Built-in apps](./apps.md): The apps nixlab ships, and the App Catalog's (apps.<name>.enable). Your own go in apps/ (see Adding Apps).
- [Backups and monitoring](./operations.md): Backups of your volumes, and alerts when something goes wrong.
- [Power, NAS and remote access](./hardware.md): A UPS, file shares on a node's disks, and reaching the lab from outside.

