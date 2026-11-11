# Managing Secrets

All secrets are stored in `secrets.yaml`, encrypted with your [age](https://github.com/FiloSottile/age) key via [SOPS](https://github.com/getsops/sops). The file is safe to commit - SOPS encryption means only the holder of the age private key can decrypt it. [sops-nix](https://github.com/Mic92/sops-nix) decrypts the file at activation time and writes each secret the nodes need to a tmpfs path. The cluster's secrets are decrypted in the cluster instead (see [How app secrets reach the cluster](#how-app-secrets-reach-the-cluster)).

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
| `sso_nextcloud_client_secret` | the OIDC client secret Nextcloud and Dex share; only with [single sign-on](./sso.md) (it replaces `nextcloud_sso_secret`) |
| `telegram_proxy_secret` | 32 hex characters (`openssl rand -hex 16`); only with the [Telegram proxy](./services.md#telegram-proxy-mtg) |
| `grafana_admin_password` | Grafana's `admin` login; only with [monitoring](./monitoring.md) |
| `monitoring_telegram_bot_token`, `monitoring_discord_webhook_url`, `monitoring_smtp_password`, `monitoring_webhook_url`, `monitoring_deadmans_switch_url` | one per enabled [notification channel](./monitoring.md#notifications) |

## Adding a new secret

All in your homelab repo; nixlab itself stays untouched.

### 1. Add it to secrets.yaml

`secrets.yaml` is encrypted; SOPS decrypts it into your editor and re-encrypts on save:

```bash
sops secrets.yaml
```

```yaml
myapp_api_key: "the-actual-secret-value"
```

Or without an editor (the value never lands in your shell history):

```bash
printf '"%s"' 'the-actual-secret-value' | sops set --value-stdin secrets.yaml '["myapp_api_key"]'
```

### 2a. For a Kubernetes app: `extraSecrets`

List it in your `flake.nix`. It reaches the cluster through git like everything else (see [How app secrets reach the cluster](#how-app-secrets-reach-the-cluster)):

```nix
outputs = { nixlab, ... }: nixlab.lib.mkFlake {
  src = ./.;
  extraSecrets = [
    {
      namespace = "myapp";
      secretName = "myapp-credentials"; # the Kubernetes Secret
      secretKey = "api-key";            # key inside it
      sopsSecretName = "myapp_api_key"; # key in secrets.yaml
    }
  ];
};
```

Entries with the same `secretName` become one Secret with several keys. Use it from your app, e.g. `secretEnv.API_KEY = { secret = "myapp-credentials"; key = "api-key"; };` with `nixlab.webApp` (see [Adding Apps](./adding-charts.md#secrets)). Then just push: the Secret is created before the apps sync.

### 2b. For something on the nodes themselves: a NixOS module

Declare it with sops-nix in a module you pass as `extraNixosModules`, and use the decrypted file's path:

```nix
# flake.nix
outputs = { nixlab, ... }: nixlab.lib.mkFlake {
  src = ./.;
  extraNixosModules = [ ./nodes.nix ];
};

# nodes.nix
{ config, ... }: {
  sops.secrets.myapp_api_key = { };           # /run/secrets/myapp_api_key, root-only
  services.myapp.apiKeyFile = config.sops.secrets.myapp_api_key.path;
}
```

| Option | Default | Description |
|---|---|---|
| `owner` / `group` | `"root"` | who owns the decrypted file |
| `mode` | `"0400"` | its permissions |
| `path` | `/run/secrets/<name>` | where it's written |
| `restartUnits` | `[]` | units to restart when the value changes |

Pass the *path* to services, never the value.

## Rotating a secret

1. Open the file: `sops secrets.yaml`
2. Change the value
3. Save - SOPS re-encrypts
4. Commit and push. The cluster's Secrets update within minutes. A node secret (the k3s token, your password) reaches the nodes with their next upgrade: tonight's automatic one, or `colmena apply` now.

Pods read Secrets at start, so restart the workload afterwards, e.g. `kubectl -n nextcloud rollout restart deploy/nextcloud`. Changing `nextcloud_sso_secret` needs both Nextcloud and the WireGuard pod restarted.

## How app secrets reach the cluster

`secrets.yaml` is the one place every secret lives. Its values reach two places:
- **the nodes** (the k3s token, your login password, the cluster SSH key): sops-nix decrypts them at boot and on upgrade;
- **the cluster** (every other value: Cloudflare, Nextcloud, the VPN, backups, monitoring, your `extraSecrets`): through git, like the rest of the cluster.

The second path, step by step:
1. **The render carries `secrets.yaml` as it is in your repo, encrypted,** plus a script naming which key goes into which Kubernetes Secret. The script names keys only, never values.
2. **Argo CD syncs the `nixlab-secrets` app,** without Argo CD k3s applies it.
3. **Its Job decrypts each value and applies the Secrets.** The Job is named after a hash of the file and the script, so every change runs it again.

Decrypted values exist only in memory and in the Secrets themselves:
- **in memory:** a RAM-backed volume of the Job's pod;
- **never** in git, CI, the render, the Job's logs or Argo CD (which doesn't see the Secrets: the Job creates them);
- **no extra copy:** the Secrets are applied server-side, so no copy of the data lands in a `last-applied-configuration` annotation.

**Safeguards and access:**
- **Plaintext is refused:** the render won't build if `secrets.yaml` isn't SOPS-encrypted, because it would be published.
- **The Job's permissions** cover creating Secrets in the namespaces it serves, and changing only the Secrets it manages.
- **The age key** reaches the cluster once, from the master: the `nixlab-age-key` service places it as the `age-key` Secret in the `nixlab-secrets` namespace. Anyone who can read Secrets there (cluster-admin) can therefore decrypt `secrets.yaml`. Keep cluster-admin access as guarded as the key itself.

## Re-keying (replacing the age key)

If you need to rotate the age key itself:

```bash
# Generate a new key
age-keygen -o ~/.config/sops/age/keys.txt.new

# Update .sops.yaml with the new public key, then re-encrypt
sops updatekeys secrets.yaml

# Remove the old key
mv ~/.config/sops/age/keys.txt.new ~/.config/sops/age/keys.txt
```

Update `/persist/etc/sops-nix/keys.txt` on each node with the new private key, then redeploy.
