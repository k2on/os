{ self, ... }: {
  ark.services.home = { pkgs, service, config, ... }: {
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
        auth_oidc:
          client_id: home
          client_secret: !secret oidc_client_secret
          discovery_url: "https://id.koon.us/oauth2/openid/home/.well-known/openid-configuration"
          features:
            automatic_person_creation: true
            default_redirect: true
          id_token_signing_alg: ES256
          roles:
            admin: "home_admins@id.koon.us"
            user: "home_users@id.koon.us"
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
          "${config.sops.templates."hass-secrets.yaml".path}:/config/secrets.yaml"
          "${pkgs.home-assistant-custom-components.auth_oidc}/custom_components/auth_oidc:/config/custom_components/auth_oidc:ro"
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

    sops.secrets."home_oidc_client_secret" = {
      sopsFile = "${self}/secrets/sops/oidc/home.yaml";
      owner = "kanidm";
    };

    sops.templates."hass-secrets.yaml" = {
      content = ''
        oidc_client_secret: "${config.sops.placeholder.home_oidc_client_secret}"
      '';
      restartUnits = [ "podman-homeassistant.service" ];
    };
  };
}
