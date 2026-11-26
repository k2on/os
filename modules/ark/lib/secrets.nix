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
#     foo_api_key = { file = "foo"; };                 # in secrets/vars/foo.yaml with
#     foo_api_user = { file = "foo"; };                # others a CLI reads together
#     foo_smtp_password = { optional = true; };        # filled in by a command, later
#   };
#
# An optional secret is one some command fills in (`ark service <name> ...`)
# rather than `ark secrets`, which leaves it alone. Until its file exists a
# host builds without it: it is not in sops.secrets, so a module tests
# `config.sops.secrets ? <name>` to use it only once it is there.
#
# Every attribute other than `generate`, `file` and `optional` is passed through to
# sops.secrets.<name>, so owner/group/mode/restartUnits/... work as usual.
# Each declaration reads secrets/vars/<file>.yaml (by default one file per
# key), encrypted to ark.adminKeys (secrets/ark.nix) plus ark.hostKey of
# every host that declares anything in that file. A host whose secret file is missing fails to build with a
# pointer to `ark secrets` (modules/shell.nix), which reads the
# `arkSecrets` flake output below to create missing files (generating or
# prompting) and to rekey files whose recipients changed.
# `ark secrets --dry-run` only lists.
#
# The same key on a terranix aspect (a provider needing an API token)
# declares an admin-only secret: encrypted to ark.adminKeys alone and
# exported into the environment of `ark plan/apply/destroy` under its name.
# It reaches the manifest through a terranix-class consumer on infra-base.
# These all share one file, secrets/vars/infra.yaml, so loading them costs
# a single decryption (one yubikey touch) per command.
{
  inputs,
  root,
  lib,
  config,
  ...
}:
let
  varsDir = "secrets/vars";
  # Where a file is in the repo, to see whether it exists, and the file alone
  # in the store for sops: never the whole repo, which would make every
  # host's system change with any commit.
  varsPath = key: root + "/secrets/vars/${key}.yaml";
  varsFile =
    key:
    builtins.path {
      path = varsPath key;
      name = "${key}.yaml";
    };

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
    { name, config, ... }:
    {
      freeformType = lib.types.attrsOf lib.types.raw;
      options.key = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Secret identity (its key inside the sops file). Set it to share one value between differently owned declarations.";
      };
      options.file = lib.mkOption {
        type = lib.types.str;
        default = config.key;
        description = "File under ${varsDir} (without .yaml) holding this secret. Several secrets can share one, so a CLI reads them all with a single decryption (one yubikey touch).";
      };
      options.generate = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.bool lib.types.str);
        default = null;
        description = "null: entered by hand. true: random alphanumerics. string: shell script whose stdout is the value.";
      };
      options.optional = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Filled in by a command rather than `ark secrets`; hosts build without it (and without it in sops.secrets) until its file exists.";
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
          _: s:
          builtins.removeAttrs s [
            "generate"
            "file"
            "optional"
          ]
          // {
            sopsFile = varsFile s.file;
          }
        ) (lib.filterAttrs (_: s: !s.optional || builtins.pathExists (varsPath s.file)) config.ark.secrets);

        assertions =
          map
            (file: {
              assertion = builtins.pathExists (varsPath file);
              message = "ark: ${varsDir}/${file}.yaml is not in sops yet. Run `ark secrets` and commit it";
            })
            (
              lib.unique (
                lib.mapAttrsToList (_: s: s.file) (lib.filterAttrs (_: s: !s.optional) config.ark.secrets)
              )
            );
      };
    };

  # A home's own secrets, not a host's: declared as ark.secrets.<name> in the
  # home (with the same options), encrypted to the person's key
  # (ark.persons.<user>.ageKey) and decrypted by sops-nix's home-manager
  # module when they sign in, with ~/.config/sops/age/keys.txt, into
  # ~/.config/sops-nix/secrets/<name>. No host needs to know them.
  homeModule =
    { config, lib, ... }:
    let
      user = config.home.username;
      # Only those already in sops. A home's assertions are checked whenever it
      # is read at all, by `ark secrets` too (homeSecrets below), so a missing
      # file is a warning here, not a failure as on a host: else `ark secrets`
      # could never create it.
      present = lib.filterAttrs (_: s: builtins.pathExists (varsPath s.file)) config.ark.secrets;
      missing = lib.unique (
        lib.mapAttrsToList (_: s: s.file) (
          lib.filterAttrs (_: s: !s.optional && !builtins.pathExists (varsPath s.file)) config.ark.secrets
        )
      );
    in
    {
      imports = [ inputs.sops-nix.homeManagerModules.sops ];

      options.ark.secrets = lib.mkOption {
        type = lib.types.attrsOf secretType;
        default = { };
        description = "Secrets this home needs from ${varsDir}, encrypted to its person's ageKey.";
      };

      config = lib.mkMerge [
        {
          # The person's key, in every home: for these and any sops.secrets of
          # its own.
          sops.age.keyFile = "${config.xdg.configHome}/sops/age/keys.txt";
        }
        (lib.mkIf (config.ark.secrets != { }) {
          # Only what a home's sops-nix knows; a host's owner, restartUnits
          # and the like mean nothing here.
          sops.secrets = lib.mapAttrs (
            _: s:
            lib.filterAttrs (
              n: _:
              lib.elem n [
                "key"
                "path"
                "mode"
                "format"
              ]
            ) s
            // {
              sopsFile = varsFile s.file;
            }
          ) present;

          assertions = [
            {
              assertion = (personAgeKey user) != null;
              message = "ark: ${user}'s home has secrets, but ark.persons.${user}.ageKey (secrets/ark.nix) is not set";
            }
          ];
          warnings = map (
            file:
            "ark: ${varsDir}/${file}.yaml is not in sops yet, so this home goes without it. Run `ark secrets` and commit it"
          ) missing;
        })
      ];
    };

  personAgeKey = user: (config.ark.persons.${user} or { }).ageKey or null;

  # Fold one declarer's secrets into the accumulator: who declares them
  # (`by`, for `ark secrets` to show) and whose key they are encrypted to.
  fold =
    by: recipient: acc: s:
    let
      prev =
        acc.${s.key} or {
          generate = null;
          optional = true;
          hosts = [ ];
          recipients = [ ];
        };
    in
    acc
    // {
      ${s.key} = {
        file = s.file;
        generate = if s.generate == null then prev.generate else script s.generate;
        # Optional only if every declaration says so.
        optional = prev.optional && s.optional;
        hosts = lib.unique (prev.hosts ++ [ by ]);
        recipients = lib.unique (prev.recipients ++ lib.optional (recipient != null) recipient);
      };
    };

  # Every home's declarations: the standalone ones (homeConfigurations) and
  # those inside a host's home-manager, each once per person. A home shows
  # in `ark secrets` as ~<user>.
  homes =
    map (h: h.config) (lib.attrValues (config.flake.homeConfigurations or { }))
    ++ lib.concatMap (h: lib.attrValues (h.config.home-manager.users or { })) (
      lib.attrValues config.flake.nixosConfigurations
    );
  homeSecrets = lib.foldl' (
    acc: home:
    let
      user = home.home.username;
    in
    lib.foldl' (fold "~${user}" (personAgeKey user)) acc (lib.attrValues (home.ark.secrets or { }))
  ) { } homes;

  # Then every host's, onto the homes': { key -> { generate; optional; hosts;
  # recipients } }. The first non-null generator wins.
  hostSecrets =
    lib.foldl'
      (
        acc: host:
        lib.foldl' (fold host.config.networking.hostName host.config.ark.hostKey) acc (
          lib.attrValues host.config.ark.secrets
        )
      )
      homeSecrets
      (lib.attrValues (lib.filterAttrs (_: h: h.config ? ark) config.flake.nixosConfigurations));

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
          inherit (s) optional;
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

    # Every home, standalone or a host user's; inert where it declares none.
    den.aspects.ark-home-secrets.homeManager = homeModule;
    den.schema.user.includes = [ config.den.aspects.ark-home-secrets ];
    den.schema.home.includes = [ config.den.aspects.ark-home-secrets ];

    # For hosts declared outside den.
    flake.nixosModules.ark-secrets = nixosModule;

    # Consumed by `ark secrets`. Each secret names the file (under ${varsDir},
    # without .yaml) that holds it. sopsConfig is written to
    # ${varsDir}/.sops.yaml so `ark sops <file>.yaml` (and plain sops) work
    # from inside that directory too; one rule per file, encrypted to everyone
    # who needs any secret in it.
    flake.arkSecrets = rec {
      secrets = lib.mapAttrs (
        _: s: s // { recipients = lib.unique (config.ark.adminKeys ++ s.recipients); }
      ) (hostSecrets // infraSecrets);
      sopsConfig.creation_rules =
        lib.mapAttrsToList
          (file: recipients: {
            path_regex = "^${lib.escapeRegex file}\\.yaml$";
            key_groups = [ { age = recipients; } ];
          })
          (
            lib.foldl' (
              acc: s: acc // { ${s.file} = lib.unique ((acc.${s.file} or [ ]) ++ s.recipients); }
            ) { } (lib.attrValues secrets)
          );
    };
  };
}
