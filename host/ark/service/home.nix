{ pkgs, ... }: {
  virtualisation.oci-containers = let
    hass_config = pkgs.writeText "configuration.yaml" ''
      # Discovery
      default_config:

      # Web Server configuration
      http:
        server_host: 127.0.0.1
        use_x_forwarded_for: true
        trusted_proxies: 127.0.0.1
    '';
  in {
    backend = "podman";
    containers.homeassistant = {
      volumes = [
        "home-assistant:/config"
        # "/data/docker/hass:/config"
        "${hass_config}:/config/configuration.yaml"
        # "/run/secrets/home-assistant:/config/secrets.yaml"
      ];
      environment.TZ = "America/New_York";
      image =
        "ghcr.io/home-assistant/home-assistant:stable"; # Warning: if the tag does not change, the image will not be updated
      extraOptions = [ "--network=host" ];
    };
  };
}
