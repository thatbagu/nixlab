{
  meta = {
    category = "Media";
    description = "Stream your movies, shows and music to any device.";
    homepage = "https://jellyfin.org";
    health = "/health";
  };
  # Its NixOS module: natively, or translated into a pod on Kubernetes.
  native = {
    port = 8096;
    state = { "/var/lib/jellyfin" = "10Gi"; };
    nixos = app: { services.jellyfin.enable = true; };
  };
}
