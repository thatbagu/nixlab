{
  meta = {
    category = "Media";
    description = "Stream your movies, shows and music to any device.";
    homepage = "https://jellyfin.org";
    port = 8096;
    health = "/health";
  };
  module = { nixlab, app, ... }: nixlab.app {
    name = "jellyfin";
    inherit (app) host node;
    port = 8096;
    runtime = "native";
    # Its library, metadata and settings (the media itself is yours to
    # mount: see the catalog docs).
    state = { "/var/lib/jellyfin" = "10Gi"; };
    healthcheck = "/health";
    nixos = { services.jellyfin.enable = true; };
  };
}
