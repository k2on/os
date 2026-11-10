{ self, config, ... }:
let
  ark = config.ark;
in
{
  ark.services.home = {
    oidc.callbacks = [ "/auth/oidc/callback" ];

    # The apartment's LuxorOne login, for the daily entry QR code shown in
    # Home Assistant. One file, so reading both is one touch.
    secrets = {
      luxorone_email = {
        file = "luxorone";
      };
      luxorone_password = {
        file = "luxorone";
      };
    };

    nixos =
      {
        pkgs,
        lib,
        service,
        config,
        ...
      }:
      {
        # Its access token for the sivrad account (../sivrad/_bot.nix), and
        # everyone's picture.
        imports = [
          ./_tokens.nix
          (import ./_pictures.nix { inherit ark; })
          ./_luxer.nix
        ];

        virtualisation.oci-containers =
          let
            devices = import ./_automations/devices.nix;
            automations = import ./_automations { inherit pkgs lib; };
            lamps = names: lib.concatMapStrings (n: "\n      - ${n}") names;
            hass_config = pkgs.writeText "configuration.yaml" ''
              # Discovery
              default_config:

              # Declared in ./_automations, mounted read-only.
              automation: !include_dir_merge_list automations

              # The package room's code (./_luxer.nix) as an image, the
              # home screen's badge: tapped, the QR code to scan. Read again
              # once a day, at 06:05, just after the morning's code is made
              # (the URL changing is what makes it read again); a code asked
              # for by hand later in the day shows the next morning.
              template:
                - image:
                    - name: Package room
                      unique_id: luxer_package_room_code
                      url: "http://127.0.0.1:${toString service.port}/local/luxer/code.png?v={{ (now() - timedelta(hours=6, minutes=5)).date() }}"

              # Web Server configuration
              http:
                server_host: 127.0.0.1
                server_port: ${toString service.port}
                use_x_forwarded_for: true
                trusted_proxies: 127.0.0.1
              auth_oidc:
                client_id: ${service.oidc.clientId}
                client_secret: !secret oidc_client_secret
                discovery_url: "${service.oidc.discovery}"
                features:
                  automatic_person_creation: true
                  default_redirect: true
                id_token_signing_alg: ES256
                roles:
                  admin: "${service.oidc.groups.admin.claim}"
                  user: "${service.oidc.groups.members.claim}"
              sonos:
                media_player:
                  hosts:
                    - 10.0.0.77
                    - 10.0.0.186
              # One Adaptive Lighting switch per room, over the room's lamps
              # one by one. Not the room's Hue group (light.living_room,
              # light.bedroom_2): Adaptive Lighting can't see into a Hue
              # group, which is on while any lamp in it is, so adapting it
              # turned back on a lamp just turned off. A lamp added to a
              # room is added here too.
              # The YAML is re-imported on every start and overrides the UI.
              # The lamps are ./_automations/devices.nix's.
              adaptive_lighting:
                - name: Living room
                  lights:${lamps devices.lamps.livingRoom}
                - name: Bedroom
                  lights:${
                    lamps [
                      devices.lamps.left
                      devices.lamps.right
                      devices.lamps.mirror
                    ]
                  }
            '';
          in
          {
            backend = "podman";
            containers.homeassistant = {
              volumes = [
                "home-assistant:/config"
                # "/data/docker/hass:/config"
                "${hass_config}:/config/configuration.yaml"
                "${automations}:/config/automations:ro"
                "${config.sops.templates."hass-secrets.yaml".path}:/config/secrets.yaml"
                "${pkgs.home-assistant-custom-components.auth_oidc}/custom_components/auth_oidc:/config/custom_components/auth_oidc:ro"
                "${pkgs.home-assistant-custom-components.adaptive_lighting}/custom_components/adaptive_lighting:/config/custom_components/adaptive_lighting:ro"
              ];
              environment.TZ = "America/Chicago";
              image = "ghcr.io/home-assistant/home-assistant:stable"; # Warning: if the tag does not change, the image will not be updated
              extraOptions = [
                "--network=host"
                # podman stop kills it after 10s by default, mid-shutdown: the
                # recorder's database is then not closed cleanly. Under the
                # unit's own 120s.
                "--stop-timeout=90"
                # Zigbee dongle
                "--device=/dev/ttyUSB0:/dev/ttyUSB0"
              ];
            };
          };

        networking.firewall.allowedTCPPorts = [
          1400 # Sonos uses this port for real time communication
        ];

        sops.templates."hass-secrets.yaml" = {
          content = ''
            oidc_client_secret: "${service.oidc.clientSecret}"
          '';
          restartUnits = [ "podman-homeassistant.service" ];
        };
      };
  };
}
