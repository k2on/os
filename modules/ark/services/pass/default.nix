# Vaultwarden: passwords, for the Bitwarden apps and browser extensions,
# signed in through Kanidm.
#
# Sign-in is OpenID only (SSO_ONLY): the first time, the app sends you to
# Kanidm, Vaultwarden makes the account (matched on the mail address), and
# you choose a master password, which still unlocks the vault and never
# leaves the device. In the apps, pick "self-hosted", server
# https://pass.<mainDomain>, then "Enterprise single sign-on"; any
# identifier will do. Who may sign in: pass_members in Kanidm, which is
# everyone in a vault plus ark.groups.pass.members (secrets/ark.nix).
#
# Shared vaults are declared under ark.pass.vaults, by the secrets repo
# (secrets/services/pass/default.nix), since who shares what is the people
# side of the config. Each is a Bitwarden organization with its
# collections, and its members are confirmed into it without anyone
# clicking through the admin console:
#
#   ark.pass.vaults.house = { };       # "House": every person, one "House"
#                                      # collection, ark.groups.pass.admin owning it
#   ark.pass.vaults.work = {
#     name = "Work";
#     members = [ <persons> ];
#     owners = [ <persons> ];
#     collections = [ "Servers" "Accounts" ];
#   };
#
# Bitwarden encrypts end to end, so the server cannot add anyone to an
# organization: that takes the organization's key encrypted to the member's
# own key, which a client does. pass-vaults (./vaults, Rust) is that client:
# it holds each vault's key (the pass_vault_<name>_key secret, made by
# `ark secrets`) and writes Vaultwarden's database. It runs on deploy, when
# Vaultwarden starts, and when someone's account gets its keys (their first
# sign-in): ./vaultwarden-keys-changed.patch makes Vaultwarden write
# KEYS_CHANGED_FILE then, and a path unit watches it. The patch means
# Vaultwarden is built from source on adam. Removing a person from `members`
# takes them out of the vault (what they saw is still on their devices
# until they sync). Losing a vault's key secret means losing nothing stored
# (members still hold it), but pass-vaults can then add nobody new to it
# and says so rather than make a second one.
# `nix flake check` runs it against a real Vaultwarden (./vaults/_check.nix).
{ lib, config, ... }:
let
  ark = config.ark;
  persons = lib.attrNames ark.persons;

  # Stable ids from names, so the organization and its collections stay the
  # same rows across rebuilds and renames of their display names.
  idOf =
    seed:
    let
      h = builtins.hashString "sha256" "ark-pass:${seed}";
      s = start: len: builtins.substring start len h;
    in
    "${s 0 8}-${s 8 4}-4${s 13 3}-a${s 17 3}-${s 20 12}";

  keySecret = name: "pass_vault_${name}_key";

  vaultType = lib.types.submodule (
    { name, config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = lib.toSentenceCase name;
          description = "The organization's name, as the apps show it.";
        };
        members = lib.mkOption {
          type = lib.types.listOf (lib.types.enum persons);
          default = persons;
          defaultText = "every person in ark.persons";
          description = "Who is in it (persons, by username). Owners are in it too.";
        };
        owners = lib.mkOption {
          type = lib.types.listOf (lib.types.enum persons);
          default = ark.groups.pass.admin or [ ];
          defaultText = "ark.groups.pass.admin";
          description = "Members who own it: they manage its collections and settings in the web vault.";
        };
        collections = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
          default = [ config.name ];
          defaultText = "[ name ]";
          description = "Its collections; every member gets every one, to read and write.";
        };
      };
    }
  );

  # Vaultwarden, telling us when an account's keys are stored (see the top).
  patchVaultwarden =
    p:
    p.overrideAttrs (o: {
      patches = (o.patches or [ ]) ++ [ ./vaultwarden-keys-changed.patch ];
    });

  vaults = ark.pass.vaults;
  inVaults = lib.unique (lib.concatMap (v: v.members ++ v.owners) (lib.attrValues vaults));
in
{
  options.ark.pass.vaults = lib.mkOption {
    type = lib.types.attrsOf vaultType;
    default = { };
    description = "Shared vaults (Bitwarden organizations), by a short name that keys their ids and secrets.";
  };

  config.perSystem =
    { pkgs, inputs', ... }:
    let
      pass-vaults = pkgs.callPackage ../../_rust.nix { pname = "pass-vaults"; };
    in
    {
      packages = { inherit pass-vaults; };
      # Against the Vaultwarden adam runs: nixpkgs-unstable's, patched.
      checks.pass-vaults = pkgs.callPackage ./vaults/_check.nix {
        inherit pass-vaults;
        vaultwarden = patchVaultwarden inputs'.nixpkgs-unstable.legacyPackages.vaultwarden;
      };
    };

  config.ark.services.pass = {
    oidc = {
      callbacks = [ "/identity/connect/oidc-signin" ];
      # Everyone with a vault may sign in, plus whoever secrets/ark.nix adds.
      groups.members = lib.unique ((ark.groups.pass.members or [ ]) ++ inVaults);
    };
    secrets = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (keySecret name) {
        # 64 bytes: AES-256 key and HMAC-SHA256 key, as Bitwarden's are.
        generate = "head -c 64 /dev/urandom | base64 -w0";
        owner = "vaultwarden";
      }
    ) vaults;

    nixos =
      {
        config,
        lib,
        pkgs,
        service,
        ...
      }:
      let
        passVaults = pkgs.callPackage ../../_rust.nix { pname = "pass-vaults"; };
        # As the vaultwarden module picks it; not read off its unit, which
        # KEYS_CHANGED_FILE (its environment) is part of.
        dataDir =
          if lib.versionOlder config.system.stateVersion "24.11" then
            "/var/lib/bitwarden_rs"
          else
            "/var/lib/vaultwarden";
        keysChanged = "${dataDir}/keys-changed";
        backupDir = "/var/backup/vaultwarden";

        vaultsConfig = pkgs.writeText "pass-vaults.json" (
          builtins.toJSON {
            db = "${dataDir}/db.sqlite3";
            vaults = lib.mapAttrsToList (key: v: {
              id = idOf "vault/${key}";
              inherit (v) name;
              billingEmail = "pass@${ark.mainDomain}";
              keyFile = config.sops.secrets.${keySecret key}.path;
              collections = map (c: {
                id = idOf "vault/${key}/collection/${c}";
                name = c;
              }) v.collections;
              members = map (p: {
                email = ark.persons.${p}.mail;
                owner = lib.elem p v.owners;
              }) (lib.unique (v.members ++ v.owners));
            }) vaults;
          }
        );
      in
      {
        sops.templates."vaultwarden.env" = {
          content = ''
            SSO_CLIENT_SECRET=${service.oidc.clientSecret}
          '';
          restartUnits = [ "vaultwarden.service" ];
        };

        services.vaultwarden = {
          enable = true;
          dbBackend = "sqlite";
          package = patchVaultwarden pkgs.vaultwarden;
          domain = service.domain;
          # A consistent copy of the database and keys every night, which
          # restic below takes off the machine.
          inherit backupDir;
          environmentFile = config.sops.templates."vaultwarden.env".path;
          config = {
            ROCKET_ADDRESS = "127.0.0.1";
            ROCKET_PORT = service.port;

            SSO_ENABLED = true;
            SSO_ONLY = true;
            SSO_AUTHORITY = service.oidc.issuer;
            SSO_CLIENT_ID = service.oidc.clientId;
            SSO_SCOPES = "email profile";
            SSO_PKCE = true;
            SSO_SIGNUPS_MATCH_EMAIL = true;

            # Accounts come from Kanidm, organizations from ark.pass.vaults.
            SIGNUPS_ALLOWED = false;
            INVITATIONS_ALLOWED = false;
            SHOW_PASSWORD_HINT = false;

            KEYS_CHANGED_FILE = keysChanged;
          };
        };

        systemd.services.pass-vaults = {
          description = "Shared vaults from ark.pass.vaults in Vaultwarden";
          # On deploy when the vaults change, and whenever Vaultwarden starts.
          wantedBy = [
            "multi-user.target"
            "vaultwarden.service"
          ];
          after = [ "vaultwarden.service" ];
          requires = [ "vaultwarden.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "vaultwarden";
            Group = "vaultwarden";
            ExecStart = "${lib.getExe passVaults} ${vaultsConfig}";
          };
        };
        # And when someone's account gets its keys.
        systemd.paths.pass-vaults = {
          wantedBy = [ "paths.target" ];
          pathConfig.PathChanged = keysChanged;
        };

        services.restic.backups = lib.genAttrs [ "pass-local" "pass-remote" ] (name: {
          repository = if name == "pass-local" then "/mnt/hdd/restic/pass" else "rest:http://m1:8000/pass";
          passwordFile = config.sops.secrets.restic-password.path;
          initialize = true;
          paths = [ backupDir ];
        });
      };
  };
}
