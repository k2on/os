# Vaultwarden: passwords, for the Bitwarden apps and browser extensions,
# signed in through Kanidm.
#
# Sign-in is OpenID only (SSO_ONLY): the first time, the app sends you to
# Kanidm, Vaultwarden makes the account (matched on the mail address), and
# you choose a master password, which still unlocks the vault and never
# leaves the device. In the apps, pick "self-hosted", server
# https://pass.<mainDomain>, then "Enterprise single sign-on"; any
# identifier will do. Who may sign in: pass_members in Kanidm, which is
# everyone in a vault plus ark.access.pass.members (secrets/ark.nix).
#
# Every group in ark.groups (secrets/ark.nix) has a shared vault: a
# Bitwarden organization named after it (family -> "Family") with one
# collection of the same name, its members confirmed into it without anyone
# clicking through the admin console, and ark.access.pass.admin owning it.
#
# Bitwarden encrypts end to end, so the server cannot add anyone to an
# organization: that takes the organization's key encrypted to the member's
# own key, which a client does. pass-vaults (./vaults, Rust) is that client:
# it holds each vault's key (the pass_vault_<name>_key secret, made by
# `ark secrets`) and writes Vaultwarden's database. It runs on deploy, when
# Vaultwarden starts, and when someone's account gets its keys (their first
# sign-in): ./vaultwarden-notify.patch makes Vaultwarden write
# KEYS_CHANGED_FILE then, and a path unit watches it. The patch means
# Vaultwarden is built from source on adam. Removing a person from a group
# takes them out of the vault (what they saw is still on their devices
# until they sync). Losing a vault's key secret means losing nothing stored
# (members still hold it), but pass-vaults can then add nobody new to it
# and says so rather than make a second one.
# Mail aliases (services/mail) follow the vault a login is saved in: the
# same patch writes CIPHERS_CHANGED_FILE whenever an item is saved or
# deleted, and `pass-vaults aliases` then reads the username of each login
# in the vaults (nothing else, and never anyone's own vault) and tells
# mail-aliases on the mail host which aliases are in which group's vault.
# `nix flake check` runs it against a real Vaultwarden (./vaults/_check.nix).
{ lib, config, ... }:
let
  ark = config.ark;

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

  # Vaultwarden, telling us when an account's keys are stored and when an
  # item changes (see the top).
  patchVaultwarden =
    p:
    p.overrideAttrs (o: {
      patches = (o.patches or [ ]) ++ [ ./vaultwarden-notify.patch ];
    });

  # One per group, under the group's name, which keys its ids and secret.
  vaults = lib.mapAttrs (
    group: members:
    let
      name = lib.toSentenceCase group;
    in
    {
      inherit name members;
      owners = ark.access.pass.admin or [ ];
      collections = [ name ];
    }
  ) ark.groups;
  inVaults = lib.unique (lib.concatMap (v: v.members ++ v.owners) (lib.attrValues vaults));

  # Where mail aliases are made (services/mail), if there is mail.
  mailAliases = config.ark.mail.aliases or null;
  mailDomain = config.ark.mail.aliases.domain or null;
  aliasesKey = "${mailAliases.key}_vaultwarden";
in
{
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
        mail-aliases = pkgs.callPackage ../mail/aliases/_package.nix { };
        vaultwarden = patchVaultwarden inputs'.nixpkgs-unstable.legacyPackages.vaultwarden;
      };
    };

  config.ark.services.pass = {
    oidc = {
      callbacks = [ "/identity/connect/oidc-signin" ];
      # Everyone with a vault may sign in, plus whoever secrets/ark.nix adds.
      groups.members = lib.unique ((ark.access.pass.members or [ ]) ++ inVaults);
    };
    secrets =
      lib.mapAttrs' (
        name: _:
        lib.nameValuePair (keySecret name) {
          # 64 bytes: AES-256 key and HMAC-SHA256 key, as Bitwarden's are.
          generate = "head -c 64 /dev/urandom | base64 -w0";
          owner = "vaultwarden";
        }
      ) vaults
      // lib.optionalAttrs (mailAliases != null) {
        # mail-aliases's internal key, the mail host's secret too.
        ${aliasesKey} = {
          key = mailAliases.key;
          owner = "vaultwarden";
        };
      };

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
        ciphersChanged = "${dataDir}/ciphers-changed";
        backupDir = "/var/backup/vaultwarden";

        vaultsConfig = pkgs.writeText "pass-vaults.json" (
          builtins.toJSON (
            {
              db = "${dataDir}/db.sqlite3";
              vaults = lib.mapAttrsToList (key: v: {
                id = idOf "vault/${key}";
                group = key;
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
            // lib.optionalAttrs (mailAliases != null && mailAliases.endpoint != null) {
              aliases = {
                domain = mailDomain;
                inherit (mailAliases) endpoint;
                keyFile = config.sops.secrets.${aliasesKey}.path;
              };
            }
          )
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

            # Accounts come from Kanidm, organizations from ark.groups.
            SIGNUPS_ALLOWED = false;
            INVITATIONS_ALLOWED = false;
            SHOW_PASSWORD_HINT = false;

            KEYS_CHANGED_FILE = keysChanged;
            CIPHERS_CHANGED_FILE = ciphersChanged;
          }
          // lib.optionalAttrs (mailAliases != null) {
            # The web vault may call the alias API (services/mail) to make
            # aliases; its page only lets it reach the services listed.
            ALLOWED_CONNECT_SRC = "${mailAliases.url}/api/";
          };
        };

        systemd.services.pass-vaults = {
          description = "A shared vault per ark.groups group in Vaultwarden";
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

        # Which mail aliases are in which group's vault: whenever an item
        # changes, and after the vaults are set up.
        systemd.services.pass-aliases = lib.mkIf (mailAliases != null && mailAliases.endpoint != null) {
          description = "Tell mail-aliases which aliases are in which vault";
          wantedBy = [ "pass-vaults.service" ];
          after = [
            "pass-vaults.service"
            "tailscaled.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            User = "vaultwarden";
            Group = "vaultwarden";
            ExecStart = "${lib.getExe passVaults} aliases ${vaultsConfig}";
            # The mail host may be restarting, or the tailnet coming up.
            Restart = "on-failure";
            RestartSec = 30;
          };
        };
        systemd.paths.pass-aliases = lib.mkIf (mailAliases != null && mailAliases.endpoint != null) {
          wantedBy = [ "paths.target" ];
          pathConfig.PathChanged = ciphersChanged;
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
