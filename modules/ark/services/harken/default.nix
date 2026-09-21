{ self, config, ... }:
let
  ark = config.ark;
in
{
  ark.services.harken = {
    oidc.callbacks = [ "/auth/callback" ];
    secrets.harken_home_assistant_token = { }; # long-lived token made in Home Assistant

    nixos =
      {
        service,
        config,
        ...
      }:
      {
        imports = [ self.inputs.harken.nixosModules.default ];

        services.harken = {
          enable = true;
          port = service.port;

          # The house's speakers fetch their own bytes, and a Sonos is a
          # different computer on the LAN: loopback — the default here — is an
          # address it cannot reach, and `harken.${ark.mainDomain}` resolves to
          # the tailnet, which it is not on either. So the LAN address below is
          # the only one left, and this is what makes anything answer on it.
          #
          # `[::]` and not `0.0.0.0`, because nginx proxies to `localhost` and
          # resolves that to `[::1]` as well as `127.0.0.1` — and a v4 wildcard
          # answers only the second. It presented as intermittent 502s on
          # `/sync` and `/media/…` with nginx saying `connect() failed (111:
          # Connection refused) … upstream: "http://[::1]:31630/sync"`, a
          # request or two out of every few, whenever nginx tried that address
          # first. A v6 wildcard on Linux is dual-stack, so the LAN v4 address
          # the speakers are given below still answers.
          address = "[::]";
          openFirewall = true;

          publicUrl = "https://harken.${ark.mainDomain}";
          oidc = {
            inherit (service.oidc) issuer clientId clientSecretFile;
          };
          homeAssistant = {
            url = "https://home.${ark.mainDomain}";
            tokenFile = config.sops.secrets.harken_home_assistant_token.path;
            players = [
              "media_player.bedroom"
              "media_player.living_room"
            ];
            mediaUrl = "http://10.0.0.28:${toString service.port}";
          };
        };
      };
  };
}
