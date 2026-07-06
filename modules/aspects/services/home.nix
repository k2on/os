{ ... }: {
  ark.services.home = { pkgs, service, ... }: {
    virtualisation.oci-containers = let
      hass_config = pkgs.writeText "configuration.yaml" ''
        # Discovery
        default_config:

        automation: !include automations.yaml

        # Web Server configuration
        http:
          server_host: 127.0.0.1
          server_port: ${toString service.port}
          use_x_forwarded_for: true
          trusted_proxies: 127.0.0.1
        sonos:
          media_player:
            hosts:
              - 10.0.0.77
              - 10.0.0.186
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
        environment.TZ = "America/Chicago";
        image =
          "ghcr.io/home-assistant/home-assistant:stable"; # Warning: if the tag does not change, the image will not be updated
        extraOptions = [
          "--network=host"
          # Zigbee dongle
          "--device=/dev/ttyUSB0:/dev/ttyUSB0"
        ];
      };
    };

    networking.firewall.allowedTCPPorts = [
      1400 # Sonos uses this port for real time communication
    ];
  };
}
