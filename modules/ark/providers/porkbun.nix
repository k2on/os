{ ... }:
{
  ark.dns.providers.porkbun = {
    static = {
      terraform.required_providers.porkbun = {
        source = "cullenmcdermott/porkbun";
        version = "~> 0.3.0";
      };
      provider.porkbun = { };
    };

    records =
      { recordAttrs, lib, ... }:
      {
        resource.porkbun_dns_record = recordAttrs (
          r:
          {
            inherit (r) domain type content;
            ttl = r.ttl or 600;
          }
          // lib.optionalAttrs (r.name != "") { inherit (r) name; }
        );
      };
  };
}
