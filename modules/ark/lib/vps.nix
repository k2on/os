# VPS providers, mirroring lib/dns.nix: a host picks one with
# den.hosts.<system>.<name>.provider = "hetzner", and everything
# provider-specific (terraform provider, ssh key, server resource, how to
# reach the machine) lives under ark.vps.providers.<name>.
#
#   ark.vps.providers.hetzner = {
#     secrets.HCLOUD_TOKEN = { };                # see lib/secrets.nix
#     static = { terraform.required_providers.hcloud = ...; };   # once per provider
#     server = host: { resource.hcloud_server.${host.name} = ...; };  # once per host
#     ip = host: "\${hcloud_server.${host.name}.ipv4_address}";  # terraform refs
#     id = host: "\${hcloud_server.${host.name}.id}";
#   };
#
# Generic aspects (nixos-deploy, headscale's DNS) only use ark.vps.ip and
# ark.vps.id, so they never know which provider a host is on.
{ lib, config, ... }:
let
  providers = config.ark.vps.providers;
  providerOf =
    host:
    providers.${host.provider}
      or (throw "ark: host '${host.name}' uses unknown vps provider '${host.provider}'");
in
{
  options.ark.vps = {
    providers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.static = lib.mkOption {
            type = lib.types.raw;
            default = { };
          };
          options.server = lib.mkOption { type = lib.types.raw; };
          options.ip = lib.mkOption { type = lib.types.raw; };
          options.id = lib.mkOption { type = lib.types.raw; };
          options.secrets = lib.mkOption {
            type = lib.types.raw;
            default = { };
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
    ip = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = host: (providerOf host).ip host;
      description = "Terraform reference to a host's public IPv4 address.";
    };
    id = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = host: (providerOf host).id host;
      description = "Terraform reference to a host's instance id.";
    };
  };

  config = {
    den.schema.host.imports = [
      {
        options.provider = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Which ark.vps.providers entry creates this machine; null for hosts not managed here.";
        };
      }
    ];

    den.aspects = lib.mkMerge (
      (lib.mapAttrsToList (pname: p: {
        "vps-${pname}-static" = {
          terranix = p.static;
          inherit (p) secrets;
        };
      }) providers)
      ++ [
        {
          vps-infra.includes = lib.mapAttrsToList (n: _: config.den.aspects."vps-${n}-static") providers;
          # Anonymous like the dns consumers: a named aspect resolving on two
          # hosts would be deduped by module key and one server would vanish.
          vps-host.includes = [
            (
              { host, ... }:
              lib.optionalAttrs (host.provider != null) { terranix = (providerOf host).server host; }
            )
          ];
        }
      ]
    );

    den.schema.host.includes = [ config.den.aspects.vps-host ];
  };
}
