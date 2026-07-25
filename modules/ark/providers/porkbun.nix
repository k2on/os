{ config, ... }:
{
  den.aspects.provider-porkbun.terranix =
    config.ark.dns.forProvider "porkbun" ({ recordAttrs, lib, ... }: {
      terraform.required_providers.porkbun = {
        source = "cullenmcdermott/porkbun";
        version = "~> 0.3.0";
      };
      provider.porkbun = {};

      resource.porkbun_dns_record = recordAttrs (r:
        { inherit (r) domain type content; ttl = r.ttl or 600; }
        // lib.optionalAttrs (r.name != "") { inherit (r) name; });
    });
}
