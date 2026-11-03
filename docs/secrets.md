# Managing Secrets

All secrets are stored in `modules/system/sops/secrets.yaml`, encrypted with your [age](https://github.com/FiloSottile/age) key via [SOPS](https://github.com/getsops/sops). The file is safe to commit - SOPS encryption means only the holder of the age private key can decrypt it. [sops-nix](https://github.com/Mic92/sops-nix) decrypts the file at activation time and writes each secret to a tmpfs path that NixOS modules and the `k8s-secrets` unit can read.

## Required secrets

| Key | Used for |
|---|---|
| `cloudflare_token` | cert-manager DNS-01, ExternalDNS, DDNS (`Zone:DNS:Edit`); only with `cloudflare.enable` |
| `cloudflare_email` | `CLOUDFLARE_EMAIL_PATH` on the nodes; only with `cloudflare.enable` |
| `k3s_token` | cluster join token |
| `pihole_password` | Pi-hole admin/API; ExternalDNS logs in with it |
| `wireguard_server_private_key`, `wireguard_server_public_key`, `wireguard_server_endpoint` | WireGuard server |
| `nextcloud_admin_password`, `nextcloud_admin_username`, `nextcloud_db_password`, `nextcloud_db_username`, `nextcloud_redis_password` | Nextcloud |
| `nextcloud_sso_secret` | shared secret between the VPN proxy and Nextcloud (`openssl rand -hex 32`); without it VPN auto-login is off |
| `user_password` | hashed login password (sudo/console; SSH is keys-only) |
| `private_ssh_key` | cluster SSH key on the nodes |
| `<user>_wg_public_key` | one per enabled VPN user |
| `backup_s3_access_key_id`, `backup_s3_secret_access_key` | S3 backup target or off-site copy; only with [backups](./backups.md) |

## Adding a new secret

Adding a secret requires three changes:

1. Add the key to `secrets.yaml`
2. Declare it in `modules/system/sops/default.nix`
3. Reference the path in your module

### 1. Edit secrets.yaml

`secrets.yaml` is an encrypted YAML file. Open it in-place with SOPS - it decrypts to your editor, re-encrypts on save:

```bash
sops modules/system/sops/secrets.yaml
```

Add your key:

```yaml
myapp_api_key: "the-actual-secret-value"
```

Save and close. SOPS re-encrypts immediately. If you have not yet encrypted the file (initial setup), fill it in plain text first and then encrypt:

```bash
sops --encrypt --in-place modules/system/sops/secrets.yaml
```

Also add a placeholder to `modules/system/sops/secrets.yaml.example` so future users know the key exists:

```yaml
myapp_api_key: "your-myapp-api-key"
```

### 2. Declare in sops/default.nix

Open `modules/system/sops/default.nix` and add an entry inside `sops.secrets`:

```nix
sops.secrets = {
  # ...existing secrets...

  myapp_api_key = { owner = "${username}"; };
};
```

SOPS-nix will decrypt this key and write it to `/run/secrets/myapp_api_key` at boot.

#### Secret options

| Option | Default | Description |
|---|---|---|
| `owner` | `"root"` | Unix user that owns the decrypted file |
| `group` | `"root"` | Unix group that owns the decrypted file |
| `mode` | `"0400"` | File permissions on the decrypted file |
| `path` | `/run/secrets/<name>` | Override where the decrypted file is written |
| `neededForUsers` | `false` | Set `true` for secrets used in `users.users.<name>.hashedPasswordFile` - decrypted before user activation |
| `restartUnits` | `[]` | systemd units to restart when this secret changes |

Examples:

```nix
# Readable only by root (default)
myapp_api_key = {};

# Readable by a specific user
myapp_api_key = { owner = "${username}"; };

# Readable by all - only for genuinely public values. Anything a Kubernetes
# Secret is built from stays 0400 root: k8s-secrets runs as root.
some_public_value = { owner = "root"; mode = "0444"; };

# Written to a custom path (e.g. expected by a hardcoded service)
private_ssh_key = {
  path  = "/home/${username}/.ssh/id_ed25519";
  mode  = "0600";
  owner = "${username}";
};

# User password - must be decrypted before users are activated
user_password = { neededForUsers = true; };
```

### 3. Reference in your module

Use `config.sops.secrets.<name>.path` to get the runtime path of the decrypted file:

```nix
{ config, ... }:
{
  services.myapp = {
    enable = true;
    # Pass the path to the decrypted file, not the value itself
    apiKeyFile = config.sops.secrets.myapp_api_key.path;
  };
}
```

Or read it inline in a shell script (e.g. inside a systemd `ExecStart`):

```nix
systemd.services.myapp = {
  script = ''
    API_KEY=$(cat ${config.sops.secrets.myapp_api_key.path})
    exec myapp --api-key "$API_KEY"
  '';
};
```

## Injecting a secret into a Kubernetes Secret

Secrets for Kubernetes workloads never go through git or Argo CD. List them in `modules/system/k8s/secrets.nix` (namespace, Secret name, key, SOPS key). The master's `k8s-secrets` unit builds each Kubernetes Secret from the decrypted files (`kubectl create secret generic --from-file`, so values never appear in a process list) and re-runs automatically when a value changes.

See [Adding Apps: Secrets](./adding-charts.md#secrets) for the full workflow. Deploy the master before pushing manifests that use a new Secret.

## Rotating a secret

1. Open the file: `sops modules/system/sops/secrets.yaml`
2. Change the value
3. Save - SOPS re-encrypts
4. Redeploy: `colmena apply`

SOPS-nix detects the changed secret and restarts any units listed in `restartUnits` for that secret. Services that read the path at startup (not at module load) pick up the new value automatically on restart.

Secrets listed in `k8s/secrets.nix` restart `k8s-secrets`, which updates the Kubernetes Secret. Pods read Secrets at start, so restart the workload afterwards, e.g. `kubectl -n nextcloud rollout restart deploy/nextcloud`. Changing `nextcloud_sso_secret` needs both Nextcloud and the WireGuard pod restarted.

## Re-keying (replacing the age key)

If you need to rotate the age key itself:

```bash
# Generate a new key
age-keygen -o ~/.config/sops/age/keys.txt.new

# Update .sops.yaml with the new public key, then re-encrypt
sops updatekeys modules/system/sops/secrets.yaml

# Remove the old key
mv ~/.config/sops/age/keys.txt.new ~/.config/sops/age/keys.txt
```

Update `/persist/etc/sops-nix/keys.txt` on each node with the new private key, then redeploy.
