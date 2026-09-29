# Actual Budget, plus a twice-daily import of bank transactions through Plaid.
#
# Actual only knows SimpleFIN/GoCardless and never syncs on its own, so the
# import is a separate oneshot, money-sync (sync/, Rust). Its Actual half is
# actual-import (sync/actual-import, TypeScript on the official client
# library; sync/src/main.rs says why). `nix flake check` runs the pair end to
# end against a real Actual server and a scripted Plaid (sync/test/run.sh).
#
# Connecting a bank happens on a laptop, not on the host, and needs neither
# Actual nor money-sync running (cli/mod.rs):
#
#   ark service money link chase      # asks for the Plaid keys the first time,
#                                     # opens Plaid Link, saves the connection
#                                     # (secrets/services/money/links/chase.nix and
#                                     # the money_plaid_chase secret), then asks
#                                     # which accounts should show up in Actual
#   ark service money select chase    # change that choice later
#   ark service money accounts        # what is linked, and what syncs
#   ark service money sync            # import now (over ssh) and show the log
#
# Then commit secrets/ and deploy the host; the timer does the rest, and an
# import also runs whenever actual starts. Each chosen account appears in
# Actual under the bank's name for it, created on the first sync. The Plaid
# keys come from dashboard.plaid.com; its free trial plan covers 10 bank
# logins with real data.
#
# Actual's API can only log in with a server password, and this server is
# OpenID-only, so `money-sync seed` creates a 'money-sync' user and a
# never-expiring session for it in Actual's account.sqlite; the token is the
# money_actual_token secret. The user has to be a server ADMIN to reach a
# budget it does not own; it shows up as such under Settings -> User access.
# The same seed gives every other Actual user access to every budget, so
# whoever kanidm lets in (money_members) sees the family budget by
# themselves; the money-access timer runs it every couple of minutes.
# Nothing about the family's OpenID login changes.
{ lib, config, ... }:
let
  money = config.ark.money;
  ark = config.ark;
in
{
  options.ark.money = {
    plaid = {
      env = lib.mkOption {
        type = lib.types.enum [
          "production"
          "sandbox"
        ];
        default = "production";
        description = "Plaid environment. sandbox is for trying the pipeline with Plaid's fake banks.";
      };
      items = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule { });
        default = { };
        example = {
          chase = { };
        };
        description = ''
          Linked banks ("items" to Plaid), by a short name of your choosing.
          Each one reads its access token from the secret money_plaid_<name>.
          `ark service money link <name>` declares one and stores its token.
        '';
      };
    };

    accounts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            item = lib.mkOption {
              type = lib.types.str;
              description = "Name of the linked bank (ark.money.plaid.items) the account is on.";
            };
            mask = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Last digits of the account number, as Plaid and `ark service money accounts` show it.";
            };
            accountId = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Plaid account_id, for when two accounts on one bank share a mask.";
            };
          };
        }
      );
      default = { };
      example = {
        "Chase Checking" = {
          item = "chase";
          mask = "1234";
        };
      };
      description = "Actual account name -> the Plaid account that feeds it. Plaid accounts not listed here are ignored.";
    };

    syncId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Actual budget to import into (Settings -> Advanced -> Sync ID). Only needed when the server holds more than one budget.";
    };

    encrypted = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the budget file is end-to-end encrypted; declares the money_actual_encryption_password secret.";
    };

    history = lib.mkOption {
      type = lib.types.ints.between 1 730;
      default = 90;
      description = "Days of history Plaid fetches when a bank is first linked.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06,18:00:00";
      description = "systemd OnCalendar expression for the import; twice a day by default. It also runs once whenever actual (re)starts.";
    };
  };

  # What `ark service money ...` reads (cli/mod.rs), through `nix eval`.
  config.flake.arkServiceConfig.money = {
    plaid = {
      inherit (money.plaid) env;
      clientName = "Koon Family money";
      items = lib.attrNames money.plaid.items;
    };
    inherit (money) accounts history;
  };

  # The two halves of the importer as packages, and their end-to-end check.
  # The check runs against the Actual the money host runs (adam is built from
  # nixpkgs-unstable), the same one the client library is pinned to.
  config.perSystem =
    { pkgs, inputs', ... }:
    let
      money-sync = pkgs.callPackage ../../_rust.nix { pname = "money-sync"; };
      actual-import = pkgs.callPackage ./sync/actual-import/_package.nix { };
    in
    {
      packages = { inherit money-sync actual-import; };
      checks.money-sync = pkgs.callPackage ./sync/_check.nix {
        inherit money-sync actual-import;
        actual-server = inputs'.nixpkgs-unstable.legacyPackages.actual-server;
      };
    };

  config.ark.services.money = {
    oidc = {
      callbacks = [ "/openid/callback" ];
      # actual's openid client may not send a PKCE challenge; this lets
      # kanidm accept it either way. Flip to true once confirmed it does.
      pkce = false;
      # actual's openid client rejects kanidm's ES256 tokens ("expected RS256").
      legacyCrypto = true;
      owner = "actual";
    };

    # Everything the laptop CLI reads (Plaid keys and bank tokens) shares one
    # sops file, secrets/vars/money.yaml: one decryption, one yubikey touch,
    # per `ark service money ...` run. The rest stays one file per secret.
    secrets = {
      money_plaid_client_id = {
        file = "money";
        owner = "money-sync";
      };
      money_plaid_secret = {
        file = "money";
        owner = "money-sync";
      };
      money_actual_token = {
        generate = true;
        owner = "money-sync";
      };
    }
    // lib.optionalAttrs money.encrypted {
      money_actual_encryption_password.owner = "money-sync";
    }
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "money_plaid_${name}" {
        file = "money";
        owner = "money-sync";
      }
    ) money.plaid.items;

    nixos =
      {
        service,
        config,
        pkgs,
        ...
      }:
      let
        secret = name: config.sops.secrets.${name}.path;
        moneySync = pkgs.callPackage ../../_rust.nix { pname = "money-sync"; };
        actualImport = pkgs.callPackage ./sync/actual-import/_package.nix { };
        settings = config.services.actual.settings;
        accountDb = "${settings.serverFiles}/account.sqlite";

        syncConfig = pkgs.writeText "money-sync.json" (
          builtins.toJSON {
            actual = {
              serverURL = "http://127.0.0.1:${toString service.port}";
              tokenFile = secret "money_actual_token";
              syncId = money.syncId;
              encryptionPasswordFile =
                if money.encrypted then secret "money_actual_encryption_password" else null;
            };
            plaid = {
              inherit (money.plaid) env;
              clientIdFile = secret "money_plaid_client_id";
              secretFile = secret "money_plaid_secret";
              items = lib.mapAttrs (name: _: {
                accessTokenFile = secret "money_plaid_${name}";
              }) money.plaid.items;
            };
            inherit (money) accounts;
            stateFile = "/var/lib/money-sync/state.json";
            actualImport = lib.getExe actualImport;
            # Whoever kanidm lets in, by the short username it presents (kanidm.nix
            # sets preferShortUsername): their Actual users are created ahead of
            # their first login, with access to the budget; the admin group's
            # members as Actual admins.
            members = map (name: {
              inherit name;
              admin = lib.elem name moneyGroup.admin;
            }) (lib.unique (moneyGroup.members ++ moneyGroup.admin));
          }
        );
        moneyGroup =
          ark.groups.money or {
            members = [ ];
            admin = [ ];
          };
      in
      {
        assertions = [
          {
            assertion = actualImport.actualVersion == pkgs.actual-server.version;
            message = "actual-import pins @actual-app/api ${actualImport.actualVersion} but actual-server is ${pkgs.actual-server.version}; bump modules/ark/services/money/sync/actual-import (see its _package.nix)";
          }
        ];

        # A fixed user instead of the module's DynamicUser: the config is
        # rendered in preStart by that user, so it must be able to read the
        # client secret file.
        users.users.actual = {
          isSystemUser = true;
          group = "actual";
        };
        users.groups.actual = { };

        services.actual = {
          enable = true;
          user = "actual";
          group = "actual";
          settings = {
            hostname = "127.0.0.1"; # only nginx talks to it
            port = service.port;

            # Login only through kanidm. Anyone kanidm lets in (money_members)
            # gets an actual account on first login; money-access (below)
            # grants them the shared budget, since Actual has no config for
            # sharing a budget file.
            loginMethod = "openid";
            allowedLoginMethods = [ "openid" ];
            userCreationMode = "login";
            openId = {
              discoveryURL = service.oidc.discovery;
              client_id = service.oidc.clientId;
              client_secret._secret = service.oidc.clientSecretFile;
              server_hostname = "https://${service.domain}";
              authMethod = "openid";
            };
          };
        };

        users.users.money-sync = {
          isSystemUser = true;
          group = "money-sync";
        };
        users.groups.money-sync = { };

        # `money-sync` on the host with the unit's config, for the laptop's
        # `ark service money budgets` / `delete-budget` (which ssh in and run
        # it) and for poking at things by hand.
        environment.systemPackages = [
          (pkgs.writeShellScriptBin "money-sync" ''
            export MONEY_SYNC_CONFIG=${syncConfig}
            exec ${lib.getExe moneySync} "$@"
          '')
        ];

        # Besides the timer, one import whenever actual (re)starts: actual
        # pulls money-sync in with it. money-sync waits for actual to answer,
        # since actual gives no readiness signal.
        systemd.services.actual.wants = [ "money-sync.service" ];

        systemd.services.money-sync = {
          description = "Import bank transactions from Plaid into Actual";
          after = [
            "network-online.target"
            "actual.service"
          ];
          wants = [ "network-online.target" ];
          requires = [ "actual.service" ];
          environment.MONEY_SYNC_CONFIG = syncConfig;
          serviceConfig = {
            Type = "oneshot";
            User = "money-sync";
            Group = "money-sync";
            StateDirectory = "money-sync";
            # `+`: as root, outside the sandboxing below; the account db is 0700 actual.
            ExecStartPre = "+${lib.getExe moneySync} seed ${accountDb} ${secret "money_actual_token"}";
            ExecStart = "${lib.getExe moneySync} sync";

            PrivateTmp = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
            ];
          };
        };

        systemd.timers.money-sync = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = money.schedule;
            Persistent = true;
            RandomizedDelaySec = "10m";
          };
        };

        # The seed also grants every Actual user the shared budget; running it
        # often means a first login is followed by the budget showing up within
        # a couple of minutes, with nobody clicking through User access.
        systemd.services.money-access = {
          description = "Give every Actual user access to the shared budget";
          after = [ "actual.service" ];
          requires = [ "actual.service" ];
          environment.MONEY_SYNC_CONFIG = syncConfig;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe moneySync} seed ${accountDb} ${secret "money_actual_token"}";
          };
        };
        systemd.timers.money-access = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "2min";
          };
        };
      };
  };
}
