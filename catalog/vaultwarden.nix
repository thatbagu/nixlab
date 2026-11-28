{
  meta = {
    category = "Security";
    description = "Password manager, compatible with the Bitwarden apps.";
    homepage = "https://github.com/dani-garcia/vaultwarden";
    port = 8222;
    health = "/alive";
    settings.signups = "Let new accounts sign up (default true: create yours, then set it false).";
  };
  # Settings: signups (default true: create your account, then set it false
  # so nobody else can).
  module = { nixlab, app, ... }: nixlab.app {
    name = "vaultwarden";
    inherit (app) host node;
    port = 8222;
    runtime = "native";
    state = { "/var/lib/vaultwarden" = "1Gi"; };
    healthcheck = "/alive";
    nixos = {
      services.vaultwarden = {
        enable = true;
        config = {
          DOMAIN = "https://${app.host}";
          # The gateway may be on another node (the firewall still keeps the
          # port to it).
          ROCKET_ADDRESS = "0.0.0.0";
          ROCKET_PORT = 8222;
          SIGNUPS_ALLOWED = app.signups or true;
        };
      };
    };
  };
}
