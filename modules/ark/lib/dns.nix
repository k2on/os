{ lib, config, ... }:
let
  den = config.den;
  providerNames = builtins.attrNames config.ark.dns.providers;

  # Anonymous consumer module — deliberately NOT registered as a named aspect.
  # Named aspects get module key "terranix@<name>"; when the same name resolves
  # in two scopes (host + user, host + infra), the module system dedups by key
  # and silently drops one scope's records. Anonymous aspects get no key, so
  # every instance evaluates and empty ones merge away as {}.
  mkConsumer =
    pname: p:
    { dns_records, lib, ... }:
    let
      pd = builtins.filter (d: d.provider == pname) config.ark.domains;
      records = builtins.filter (r: builtins.any (d: d.domain == r.domain) pd) dns_records;
      recordAttrs =
        fn:
        builtins.listToAttrs (
          map (r: {
            name = if r.name == "" then "apex" else r.name;
            value = fn r;
          }) records
        );
    in
    p.records { inherit records recordAttrs lib; };
in
{
  options.ark.dns.providers = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.static = lib.mkOption {
          type = lib.types.raw;
          default = { };
        };
        options.records = lib.mkOption { type = lib.types.raw; };
      }
    );
    default = { };
  };

  config = {
    den.quirks.dns_records.description = "Provider-agnostic DNS records";

    den.aspects = lib.mkMerge (
      (lib.mapAttrsToList (pname: p: {
        "dns-${pname}-static".terranix = p.static;
      }) config.ark.dns.providers)
      ++ [
        {
          dns-host.includes = lib.mapAttrsToList (pname: p: {
            terranix = mkConsumer pname p;
          }) config.ark.dns.providers;
          dns-infra.includes =
            lib.mapAttrsToList (pname: p: { terranix = mkConsumer pname p; }) config.ark.dns.providers
            ++ map (n: den.aspects."dns-${n}-static") providerNames;
        }
      ]
    );
  };
}
