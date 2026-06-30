# Managing Secrets

All secrets are stored in `modules/system/sops/secrets.yaml`, encrypted with your [age](https://github.com/FiloSottile/age) key via [SOPS](https://github.com/getsops/sops). The file is safe to commit — SOPS encryption means only the holder of the age private key can decrypt it. [sops-nix](https://github.com/Mic92/sops-nix) decrypts the file at activation time and writes each secret to a tmpfs path that NixOS modules and the k8s deploy script can read.

## Adding a new secret

Adding a secret requires three changes:

1. Add the key to `secrets.yaml`
2. Declare it in `modules/system/sops/default.nix`
3. Reference the path in your module

### 1. Edit secrets.yaml

`secrets.yaml` is an encrypted YAML file. Open it in-place with SOPS — it decrypts to your editor, re-encrypts on save:

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
| `neededForUsers` | `false` | Set `true` for secrets used in `users.users.<name>.hashedPasswordFile` — decrypted before user activation |
| `restartUnits` | `[]` | systemd units to restart when this secret changes |

Examples:

```nix
# Readable only by root (default)
myapp_api_key = {};

# Readable by a specific user
myapp_api_key = { owner = "${username}"; };

# Readable by all (e.g. a public key or non-sensitive config)
wireguard_server_public_key = { owner = "root"; mode = "0644"; };

# Written to a custom path (e.g. expected by a hardcoded service)
private_ssh_key = {
  path  = "/home/${username}/.ssh/id_ed25519";
  mode  = "0600";
  owner = "${username}";
};

# User password — must be decrypted before users are activated
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

For secrets used by Kubernetes workloads, use `lib.mkSecretRef` in the service file instead of referencing `config.sops.secrets` directly. The k8s-deploy script reads the decrypted file and patches it into a Kubernetes Secret object.

See [Adding a Chart — Secret reference](./adding-charts.md#secret-reference) for the full workflow.

## Rotating a secret

1. Open the file: `sops modules/system/sops/secrets.yaml`
2. Change the value
3. Save — SOPS re-encrypts
4. Redeploy: `colmena apply`

SOPS-nix detects the changed secret and restarts any units listed in `restartUnits` for that secret. Services that read the path at startup (not at module load) pick up the new value automatically on restart.

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
