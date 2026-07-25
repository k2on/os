{ lib, ... }:
{
  options.ark.dns.forProvider = lib.mkOption {
    type = lib.types.raw;
    description = "Build a terranix class module from dns_records";
  };

  config = {
    den.quirks.domains.description = "Domain -> provider registry";
    den.quirks.dns_records.description = "Provider-agnostic DNS records";

    ark.dns.forProvider = provider: mkConfig:
      { domains, dns_records, lib, ... }:
        let
          providerDomains = builtins.filter (d: d.provider == provider) domains;
          records = builtins.filter
            (r: builtins.any (d: d.domain == r.domain) providerDomains)
            dns_records;
          recordAttrs = fn: builtins.listToAttrs (map (r: {
            name = if r.name == "" then "apex" else r.name;
            value = fn r;
          }) records);
        in
        mkConfig { inherit records recordAttrs providerDomains lib; };
  };
}
