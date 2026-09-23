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
  # The raw quirk data, kept in the terranix evaluation under an option the
  # JSON never sees, so lib/terranix.nix can hand every record to the VM test
  # (test/vm.nix) without knowing any provider.
  recordsOption = {
    options.ark.dnsRecords = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [ ];
    };
  };
  keepRecords =
    { dns_records, ... }:
    {
      ark.dnsRecords = dns_records;
    };
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
        options.secrets = lib.mkOption {
          type = lib.types.raw;
          default = { };
          description = "API tokens the provider reads from its environment; see lib/secrets.nix.";
        };
        options.mock = lib.mkOption {
          type = lib.types.raw;
          default = { };
          description = "`tofu test` mock_provider blocks for the offline infra test, keyed by terraform provider name; see lib/tftest.nix.";
        };
      }
    );
    default = { };
  };

  config = {
    den.quirks.dns_records.description = "Provider-agnostic DNS records";

    den.aspects = lib.mkMerge (
      (lib.mapAttrsToList (pname: p: {
        "dns-${pname}-static" = {
          terranix = p.static;
          inherit (p) secrets;
        };
      }) config.ark.dns.providers)
      ++ [
        {
          dns-host.includes =
            lib.mapAttrsToList (pname: p: {
              terranix = mkConsumer pname p;
            }) config.ark.dns.providers
            ++ [ { terranix = keepRecords; } ];
          dns-records-option.terranix = recordsOption;
          dns-infra.includes =
            lib.mapAttrsToList (pname: p: { terranix = mkConsumer pname p; }) config.ark.dns.providers
            ++ map (n: den.aspects."dns-${n}-static") providerNames
            ++ [
              den.aspects.dns-records-option
              { terranix = keepRecords; }
            ];
        }
      ]
    );
  };
}
