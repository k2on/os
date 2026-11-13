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
      # The terraform resource name: the record's name, or its `id` where
      # two records share a name (an MX beside an A at the apex). A name a
      # level down (apple.devices) has its dots made underscores: terraform
      # names take only letters, digits, underscores and dashes.
      recordId =
        r:
        r.id or (
          if r.name == "" then
            "apex"
          else
            lib.concatMapStrings (c: if builtins.match "[A-Za-z0-9_-]" c != null then c else "_") (
              lib.stringToCharacters r.name
            )
        );
      ids = map recordId records;
      dup = lib.filter (i: lib.count (j: j == i) ids > 1) (lib.unique ids);
      recordAttrs =
        fn:
        if dup != [ ] then
          throw "ark: DNS records for ${pname} share a resource name: ${toString dup}; give one an `id`"
        else
          builtins.listToAttrs (
            map (r: {
              name = recordId r;
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
        options.secrets = lib.mkOption {
          type = lib.types.raw;
          default = { };
          description = "API tokens the provider reads from its environment; see lib/secrets.nix.";
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
