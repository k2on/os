{
  self,
  config,
  lib,
  ...
}:
let
  ark = config.ark;
in
{
  # Reachable off the tailnet only from the addresses in
  # ark.publicFrom.harken (secrets/ark.nix; lib/public.nix), and not at
  # all without them: /media is served to anyone who asks (the speakers
  # fetch it so), so Harken is never public to the whole internet.
  ark.public = lib.mkIf (ark.publicFrom ? harken) { harken = 443; };

  ark.services.harken = {
    oidc.callbacks = [ "/auth/callback" ];
    secrets.harken_home_assistant_token = { }; # long-lived token made in Home Assistant

    nixos =
      {
        service,
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [ self.inputs.koon-apps.nixosModules.default ];

        services.harken = {
          enable = true;
          # The browser client at /, which the old harken repo served by
          # default and the apps monorepo leaves to the host: the server
          # build, which signs in against this server (`harken-web` is the
          # seeded demo GitHub Pages publishes).
          web = self.inputs.koon-apps.packages.${pkgs.stdenv.hostPlatform.system}.harken-web-server;
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
          # The `picture` claim (ark.oidc.picture) is on photos.*, ark's own
          # nginx at its tailnet address, which Harken fetches from only when
          # told: otherwise only public addresses and Kanidm's own host.
          pictureHosts = lib.optional (ark.oidc.picture != null) (
            builtins.head (lib.splitString "/" (lib.removePrefix "https://" ark.oidc.picture))
          );
          # Classical recordings free to download (github.com/k2on/classical),
          # downloaded into the state directory at boot and on Settings'
          # Resync, which only the library's role may ask: max's Kanidm id,
          # as Harken knows him (the sign-in's `sub`).
          catalogue = "https://k2on.github.io/classical/catalogue.json";

          roles.library = [ "3f78ea05-f996-48c1-857d-6467f5621251" ];
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
