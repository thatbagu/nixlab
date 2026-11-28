# Built-in apps

The apps nixlab ships, and the App Catalog's (apps.<name>.enable). Your own go in apps/ (see Adding Apps). All of these go in `vars.nix`.

<!-- Generated from system/vars/options.nix (nix build .#options-doc): don't edit by hand. -->


## `apps`

Apps from nixlab's catalog (docs: App Catalog), each on with apps.&lt;name&gt;.enable = true.

- **`apps.<name>.enable`**: Run this catalog app.
  <br>*boolean*, default `false`
- **`apps.<name>.host`**: Where it's reached (default &lt;name&gt;.&lt;domain&gt;).
  <br>*null or string*, default `null`
- **`apps.<name>.nixos`**: NixOS settings for the app's service, over the catalog's (e.g. services.vaultwarden.config.SMTP_HOST): natively on its node, or in its image on Kubernetes.
  <br>*attribute set of anything*, default `{ }`
- **`apps.<name>.node`**: The node it runs on, by hostname (default: natively, the first master; on Kubernetes, wherever it's scheduled).
  <br>*null or string*, default `null`
- **`apps.<name>.runtime`**: How it runs: "kubernetes" (a pod, with failover and replicated storage) or "native" (its NixOS module on a node). Default: kubernetes when the lab runs k3s (kubernetes.enable), else native.
  <br>*null or one of "native", "kubernetes"*, default `null`


## `nextcloud`

Nextcloud (VPN-only): files, calendar and contacts.

- **`nextcloud.enable`**: Run Nextcloud.
  <br>*boolean*, default `kubernetes.enable`


## `signalProxy`

A Signal TLS proxy at signal.&lt;domain&gt; (needs Cloudflare).

- **`signalProxy.enable`**: Run the Signal proxy.
  <br>*boolean*, default `kubernetes.enable`


## `telegramProxy`

A Telegram proxy on port 443, disguised as HTTPS.

- **`telegramProxy.enable`**: Run the Telegram proxy.
  <br>*boolean*, default `false`


## `sso`

Single sign-on (OIDC) at https://auth.&lt;domain&gt;, VPN-only (docs: SSO). More in the [guide](../sso.md), including settings not listed here.

- **`sso.enable`**: Run single sign-on.
  <br>*boolean*, default `false`


## `statusPage`

A status page at status.&lt;domain&gt;: a monitor per app, made from your apps (docs: Adding Apps).

- **`statusPage.enable`**: Run the status page (Gatus).
  <br>*boolean*, default `false`


## `auth`

Logging in to apps with auth = true, at https://login.&lt;domain&gt; (docs: Adding Apps).

- **`auth.allowedEmails`**: Who may get in, by the email their provider vouches for.
  <br>*list of string*, default `[ ]`
- **`auth.oidcIssuer`**: provider = "oidc": the provider's issuer URL.
  <br>*string*, default `""`
- **`auth.provider`**: Who people log in with.
  <br>*one of "github", "google", "oidc"*, default `"github"`


