{ config, lib, ... }:
let
  ark = config.ark;
  clients = ark.oidc.clients;
in
{
  # kanidm terminates its own TLS; the vps passes id.* through to it (lib/public.nix).
  ark.public.id = 8443;

  flake.nixosModules.kanidm =
    { pkgs, config, ... }:
    {
      # kanidm's own copy of every service's client secret. The service's
      # copy is declared by ark.services (lib/services.nix) on whichever
      # host runs it; both read the same secrets/vars file.
      ark.secrets = lib.mapAttrs' (
        _: o:
        lib.nameValuePair "${o.secret}_kanidm" {
          key = o.secret;
          owner = "kanidm";
        }
      ) clients;

      services.kanidm = {
        package = pkgs.kanidmWithSecretProvisioning_1_10;
        server = {
          enable = true;
          settings = {
            domain = "id.${ark.mainDomain}";
            origin = "https://id.${ark.mainDomain}";
            bindaddress = "0.0.0.0:8443";

            tls_chain = "/var/lib/acme/${ark.mainDomain}/fullchain.pem";
            tls_key = "/var/lib/acme/${ark.mainDomain}/key.pem";

          };
        };

        client = {
          enable = true;
          settings.uri = "https://id.${ark.mainDomain}";
        };

        # Persons and group memberships come from the secrets repo
        # (secrets/ark.nix); clients from each service's `oidc` (lib/oidc.nix).
        provision = {
          enable = true;

          persons = lib.mapAttrs (_: p: {
            inherit (p) displayName;
            mailAddresses = [ p.mail ];
          }) ark.persons;

          groups = lib.concatMapAttrs (
            _: o: lib.mapAttrs' (_: g: lib.nameValuePair g.name { inherit (g) members; }) o.groups
          ) clients;

          systems.oauth2 = lib.mapAttrs (
            _: o:
            {
              inherit (o) displayName;
              originUrl = o.callbacks;
              originLanding = o.landing;
              basicSecretFile = config.sops.secrets."${o.secret}_kanidm".path;
              preferShortUsername = true;
              scopeMaps = lib.mapAttrs' (_: g: lib.nameValuePair g.name o.scopes) o.groups;
              allowInsecureClientDisablePkce = !o.pkce;
              enableLegacyCrypto = o.legacyCrypto;
            }
            // lib.optionalAttrs (o.icon != null) { imageFile = o.icon; }
          ) clients;
        };
      };

      networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8443 ];

      systemd.services.kanidm = {
        wants = [ "acme-finished-${ark.mainDomain}.target" ];
        after = [ "acme-finished-${ark.mainDomain}.target" ];
      };

      systemd.services.kanidm.serviceConfig.ExecReload = "/run/current-system/sw/bin/kill -HUP $MAINPID";
    };
}
