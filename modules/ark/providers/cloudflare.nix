{ lib, config, ... }:
let
  zoneKey = d: lib.replaceStrings [ "." ] [ "_" ] d;
in
{
  ark.dns.providers.cloudflare = {
    secrets.CLOUDFLARE_API_TOKEN = { };

    # Offline test: zone lookups answer with a fixed id.
    mock.cloudflare.mock_data.cloudflare_zone.defaults.id = "0123456789abcdef0123456789abcdef";

    static = {
      terraform.required_providers.cloudflare = {
        source = "cloudflare/cloudflare";
        version = "~> 5.22.0";
      };
      provider.cloudflare = { };

      data.cloudflare_zone = builtins.listToAttrs (
        map (d: {
          name = zoneKey d.domain;
          value.filter.name = d.domain;
        }) (builtins.filter (d: d.provider == "cloudflare") config.ark.domains)
      );
    };

    records =
      { recordAttrs, lib, ... }:
      {
        resource.cloudflare_dns_record = recordAttrs (r: {
          zone_id = "\${data.cloudflare_zone.${zoneKey r.domain}.id}";
          name = if r.name == "" then "@" else r.name;
          inherit (r) type content;
          ttl = r.ttl or 600;
        });
      };
  };
}
