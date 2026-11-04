#!/usr/bin/env python3
"""Turn a checkout of the template into a testable configuration, in place.

The template ships placeholders (no nodes, no users, no secrets), so CI fills
in a small fake setup: a master and a worker, two VPN users, the example
secrets file (never decrypted at build time), plus per-variant settings.

Usage: ci/fixture.py <variant>      (run from the repo root; modifies files!)
Variants: default, no-cloudflare, backups-s3, backups-nfs-offsite,
          monitoring, monitoring-e2e, example-app, bad-backup-target, bad-offsite
"""
import os
import shutil
import subprocess
import sys

VARIANTS = {
    "default": [],
    "no-cloudflare": [
        ("  cloudflare.enable = true;", "  cloudflare.enable = false;"),
        ('  domain = "yourdomain.example.com";', '  domain = "home.arpa";'),
    ],
    "backups-s3": [
        ('    enable = false;\n    target = "s3://nixlab-backups@us-east-1/";',
         '    enable = true;\n    target = "s3://nixlab-backups@us-east-1/";'),
        ('    s3Endpoint = ""; # e.g.', '    s3Endpoint = "https://s3.example.com"; # e.g.'),
    ],
    "backups-nfs-offsite": [
        ('    enable = false;\n    target = "s3://nixlab-backups@us-east-1/";',
         '    enable = true;\n    target = "nfs://192.168.1.10:/volume1/backups";'),
        ("    offsite = {\n      enable = false;", "    offsite = {\n      enable = true;"),
    ],
    "monitoring": [
        ("  monitoring = {\n    enable = false;", "  monitoring = {\n    enable = true;"),
        ("telegram = { enable = false; chatId = 0; };", "telegram = { enable = true; chatId = 123456; };"),
        ("discord.enable = false;", "discord.enable = true;"),
        ("      email = {                                          # monitoring_smtp_password\n        enable = false;",
         "      email = {                                          # monitoring_smtp_password\n        enable = true;"),
        ("webhook.enable = false;", "webhook.enable = true;"),
        ("deadMansSwitch.enable = false;", "deadMansSwitch.enable = true;"),
    ],
    # The live monitoring test: only channels an in-cluster echo server can
    # stand in for.
    "monitoring-e2e": [
        ("  monitoring = {\n    enable = false;", "  monitoring = {\n    enable = true;"),
        ("webhook.enable = false;", "webhook.enable = true;"),
        ("deadMansSwitch.enable = false;", "deadMansSwitch.enable = true;"),
    ],
    "example-app": [],  # handled below
    "bad-backup-target": [
        ('    enable = false;\n    target = "s3://nixlab-backups@us-east-1/";',
         '    enable = true;\n    target = "ftp://nope";'),
    ],
    "bad-offsite": [
        ('    enable = false;\n    target = "s3://nixlab-backups@us-east-1/";',
         '    enable = true;\n    target = "s3://nixlab-backups@us-east-1/";'),
        ("    offsite = {\n      enable = false;", "    offsite = {\n      enable = true;"),
    ],
}

# Present in every variant.
COMMON = [
    ('  username = "youruser";', '  username = "ci";'),
    ("  nodes = {\n", """  nodes = {
    tmaster = { hostname = "tmaster"; master = true;  disk = "/dev/vda"; tags = [ "homelab" "master" ]; };
    tworker = { hostname = "tworker"; master = false; disk = "/dev/vda"; tags = [ "homelab" "worker" ]; };
"""),
    ("  wireguardUsers = {\n", """  wireguardUsers = {
    alice = { ip = "10.0.100.2"; group = "admin";  publicKeySecret = "alice_wg_public_key"; allowedIPs = "0.0.0.0/0"; nextcloudUser = "alice"; description = "ci"; enabled = true; };
    bob   = { ip = "10.0.100.3"; group = "family"; publicKeySecret = "bob_wg_public_key";   allowedIPs = "10.0.100.0/24"; description = "ci"; enabled = true; };
"""),
]


def replace_once(path, old, new):
    with open(path) as f:
        s = f.read()
    if s.count(old) != 1:
        sys.exit(f"fixture: expected exactly one {old!r} in {path}, found {s.count(old)}. "
                 "Update ci/fixture.py to match vars.nix.")
    with open(path, "w") as f:
        f.write(s.replace(old, new, 1))


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in VARIANTS:
        sys.exit(__doc__)
    variant = sys.argv[1]
    if not os.path.exists("vars.nix"):
        sys.exit("fixture: run from the repo root")

    for old, new in COMMON + VARIANTS[variant]:
        replace_once("vars.nix", old, new)

    for host in ("tmaster", "tworker"):
        os.makedirs(f"hosts/{host}", exist_ok=True)
        shutil.copy("hosts/hardware-configuration.nix", f"hosts/{host}/hardware-configuration.nix")
    if not os.path.exists("system/sops/secrets.yaml"):
        shutil.copy("system/sops/secrets.yaml.example", "system/sops/secrets.yaml")
        # sops-nix checks at build time that every declared secret exists.
        with open("system/sops/secrets.yaml", "a") as f:
            f.write('\nalice_wg_public_key: "ci"\nbob_wg_public_key: "ci"\n'
                    'backup_s3_access_key_id: "ci"\nbackup_s3_secret_access_key: "ci"\n'
                    'grafana_admin_password: "ci"\nmonitoring_telegram_bot_token: "ci"\n'
                    'monitoring_discord_webhook_url: "ci"\nmonitoring_smtp_password: "ci"\n'
                    'monitoring_webhook_url: "ci"\nmonitoring_deadmans_switch_url: "ci"\n')

    if variant == "example-app":
        os.rename("apps/_example.nix", "apps/uptime-kuma.nix")

    # Flakes only see files git knows about.
    subprocess.run(["git", "add", "-A", "-f", "vars.nix", "hosts", "apps",
                    "system/sops/secrets.yaml"], check=True)
    print(f"fixture: applied variant {variant!r}")


if __name__ == "__main__":
    main()
