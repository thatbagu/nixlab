# Machines and access

Who you are on the nodes, which machines make up the lab, and how they're kept up to date. All of these go in `vars.nix`.

<!-- Generated from modules/vars/options.nix (nix build .#options-doc): don't edit by hand. -->

- **`username`**: Your Linux user on every node.
  <br>*string*
- **`timezone`**: Every node's timezone (timedatectl list-timezones).
  <br>*string*, default `"UTC"`
- **`clusterSshKey`**: The SSH public key that may log in to every node.
  <br>*string*
- **`profile`**: "cluster" (several machines) or "single" (everything on one machine: no Longhorn, MetalLB or Argo CD by default).
  <br>*one of "cluster", "single"*, default `"cluster"`

## `nodes`

The machines, each one a node: one machine with profile = "single", otherwise masters and workers. More in the [guide](../adding-nodes.md), including settings not listed here.

- **`nodes.<name>.address`**: A fixed IP (DHCP reservation): deploys and joins without mDNS. Needed with profile = "single".
  <br>*null or string*, default `null`
- **`nodes.<name>.disk`**: The disk nixlab installs on (erased), e.g. /dev/nvme0n1.
  <br>*string*
- **`nodes.<name>.encrypt`**: Encrypt the disk, unlocked by the TPM (docs: Encryption at Rest). Only at install.
  <br>*boolean*, default `false`
- **`nodes.<name>.hostname`**: The node's hostname: hosts/&lt;hostname&gt;/hardware-configuration.nix.
  <br>*string*
- **`nodes.<name>.master`**: Runs the control plane (k3s server and etcd). One master, or three for high availability.
  <br>*boolean*, default `false`
- **`nodes.<name>.system`**: The node's platform (aarch64-linux for a Raspberry Pi 4/5).
  <br>*one of "x86_64-linux", "aarch64-linux"*, default `"x86_64-linux"`
- **`nodes.<name>.tags`**: Colmena tags, for deploying to a group of nodes.
  <br>*list of string*, default `[ ]`


## `diskEncryption`

Disk encryption settings (docs: Encryption at Rest). More in the [guide](../encryption.md), including settings not listed here.



## `k3s`

k3s tuning (docs: Configuration, k3s). More in the [guide](../configuration.md#k3s), including settings not listed here.

- **`k3s.stableNodePasswords`**: Reinstalled workers rejoin with the same node password (new clusters only).
  <br>*boolean*, default `false`


## `autoUpgrade`

Upgrades of the nodes from gitRepository (docs: Updates). More in the [guide](../updates.md), including settings not listed here.

- **`autoUpgrade.enable`**: Upgrade the nodes from main of gitRepository.
  <br>*boolean*, default `true`
- **`autoUpgrade.mode`**: nightly: every node upgrades at night, one after another. continuous: every node deploys each new commit to main within a minute (comin), and stays on its last good system if a deploy fails.
  <br>*one of "nightly", "continuous"*, default `"nightly"`
- **`autoUpgrade.pollSeconds`**: continuous: how often each node checks main for a new commit.
  <br>*positive integer, meaning >0*, default `60`
- **`autoUpgrade.staggerSeconds`**: continuous: each node deploys a new commit this much after the one before it, masters first (the nightly upgrade's order). 0: all at once.
  <br>*unsigned integer, meaning >=0*, default `60`


## `binaryCache`

A binary cache the nodes download their upgrades from, instead of building them (docs: Updates).

- **`binaryCache.publicKey`**: The cache's signing key: nodes only trust what it signed.
  <br>*string*, default `""`
- **`binaryCache.url`**: The cache's URL (empty: off). CI can push the nodes' builds there (CACHIX_NODE_CACHE).
  <br>*string*, default `""`


