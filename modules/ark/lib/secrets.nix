# Declarative sops secrets, in the spirit of agenix-rekey and clan vars.
#
# Declare secrets on any aspect under the `secrets` quirk (an ark.services
# spec accepts the same attrset and forwards it):
#
#   den.aspects.foo.secrets = {
#     foo_api_key = { };                               # entered by hand
#     foo_oidc_client_secret = { generate = true; };   # 48 random alphanumerics
#     foo_oidc_client_secret_kanidm = {                # same value, another owner
#       key = "foo_oidc_client_secret";
#       owner = "kanidm";
#     };
#     foo_cert = { generate = "openssl ..."; mode = "0400"; };  # custom script
#   };
#
# Every attribute other than `generate` is passed through to
# sops.secrets.<name>, so owner/group/mode/restartUnits/... work as usual.
# Each declaration reads secrets/vars/<key>.yaml, encrypted to
# ark.adminKeys (secrets/ark.nix) plus ark.hostKey of every host that
# declares it. A host whose secret file is missing fails to build with a
# pointer to `ark secrets` (modules/shell.nix), which reads the
# `arkSecrets` flake output below to create missing files (generating or
# prompting) and to rekey files whose recipients changed.
# `ark secrets --dry-run` only lists.
#
# The same key on a terranix aspect (a provider needing an API token)
# declares an admin-only secret: encrypted to ark.adminKeys alone and
# exported into the environment of `ark plan/push/destroy` under its name.
# It reaches the manifest through a terranix-class consumer on infra-base.
# These all share one file, secrets/vars/infra.yaml, so loading them costs
# a single decryption (one yubikey touch) per command.
{
  self,
  inputs,
  lib,
  config,
  ...
}:
let
  varsDir = "secrets/vars";
  varsFile = key: "${self}/${varsDir}/${key}.yaml";

  alnum = "tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48";

  # `true` becomes the default script so the CLI only ever sees null or a script.
  script =
    generate:
    if generate == true then
      alnum
    else if generate == false then
      null
    else
      generate;

  secretType = lib.types.submodule (
    { name, ... }:
    {
      freeformType = lib.types.attrsOf lib.types.raw;
      options.key = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Secret identity (file name under ${varsDir}). Set it to share one value between differently owned declarations.";
      };
      options.generate = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.bool lib.types.str);
        default = null;
        description = "null: entered by hand. true: random alphanumerics. string: shell script whose stdout is the value.";
      };
    }
  );

  nixosModule =
    { config, lib, ... }:
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      options.ark = {
        hostKey = lib.mkOption {
          type = lib.types.str;
          description = "age recipient of this host: ssh-to-age of its ed25519 host key.";
        };
        secrets = lib.mkOption {
          type = lib.types.attrsOf secretType;
          default = { };
          description = "Secrets this host needs from ${varsDir}; normally fed by the `secrets` quirk.";
        };
      };

      config = {
        sops.secrets = lib.mapAttrs (
          _: s: builtins.removeAttrs s [ "generate" ] // { sopsFile = varsFile s.key; }
        ) config.ark.secrets;

        assertions = map (key: {
          assertion = builtins.pathExists (varsFile key);
          message = "ark: secret '${key}' is not in sops yet. Run `ark secrets` and commit ${varsDir}/${key}.yaml";
        }) (lib.unique (lib.mapAttrsToList (_: s: s.key) config.ark.secrets));
      };
    };

  # Fold every host's declarations into { key -> { generate; hosts; recipients } }.
  # The first non-null generator wins.
  hostSecrets = lib.foldl' (
    acc: host:
    lib.foldl' (
      acc: s:
      let
        prev =
          acc.${s.key} or {
            generate = null;
            hosts = [ ];
            recipients = [ ];
          };
      in
      acc
      // {
        ${s.key} = {
          file = s.key;
          generate = if s.generate == null then prev.generate else script s.generate;
          hosts = lib.unique (prev.hosts ++ [ host.config.networking.hostName ]);
          recipients = lib.unique (prev.recipients ++ [ host.config.ark.hostKey ]);
        };
      }
    ) acc (lib.attrValues host.config.ark.secrets)
  ) { } (lib.attrValues (lib.filterAttrs (_: h: h.config ? ark) config.flake.nixosConfigurations));

  # The terranix consumer declares its own option so the real terranix
  # evaluation accepts it (custom options are dropped from config.tf.json).
  terranixModule =
    { secrets, lib, ... }:
    {
      options.ark.secrets = lib.mkOption {
        type = lib.types.attrsOf secretType;
        default = { };
      };
      config.ark.secrets = lib.mkMerge secrets;
    };

  # Same modules terranix builds infra from, evaluated only for ark.secrets:
  # with checking off the terraform definitions need no declarations.
  infraSecrets =
    lib.mapAttrs'
      (
        _: s:
        lib.nameValuePair s.key {
          file = "infra";
          generate = script s.generate;
          hosts = [ ];
          recipients = [ ];
        }
      )
      (lib.evalModules {
        modules = [
          { _module.check = false; }
          (config.den.lib.aspects.resolve "terranix" config.den.aspects.infra-base)
        ];
      }).config.ark.secrets;
in
{
  options.ark.adminKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    description = "age recipients that can read every secret (the admin yubikey).";
  };

  config = {
    den.quirks.secrets.description = "Secret declarations: { <name> = { generate ?, key ?, <sops.secrets.* options> }; }";

    den.aspects.ark-secrets.nixos =
      { secrets, ... }:
      {
        imports = [ nixosModule ];
        ark.secrets = lib.mkMerge secrets;
      };
    den.aspects.ark-infra-secrets.terranix = terranixModule;

    # Active on every host; inert (empty) where nothing declares secrets.
    # The infra side is included by infra-base (lib/terranix.nix).
    den.schema.host.includes = [ config.den.aspects.ark-secrets ];

    # For hosts declared outside den.
    flake.nixosModules.ark-secrets = nixosModule;

    # Consumed by `ark secrets`. Each secret names the file (under ${varsDir},
    # without .yaml) that holds it. sopsConfig is written to
    # ${varsDir}/.sops.yaml so plain `sops <file>.yaml` works from inside
    # that directory too; one rule per file.
    flake.arkSecrets = rec {
      secrets = lib.mapAttrs (
        _: s: s // { recipients = lib.unique (config.ark.adminKeys ++ s.recipients); }
      ) (hostSecrets // infraSecrets);
      sopsConfig.creation_rules = lib.mapAttrsToList (file: recipients: {
        path_regex = "^${lib.escapeRegex file}\\.yaml$";
        key_groups = [ { age = recipients; } ];
      }) (lib.foldl' (acc: s: acc // { ${s.file} = s.recipients; }) { } (lib.attrValues secrets));
    };
  };
}
