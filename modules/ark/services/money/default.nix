# money, the household's budget (koon-apps' money/: services.money), at
# money.<mainDomain>: its sync server, the browser client, and the phones'
# server, with an importer of its own that asks Plaid for the banks' new
# transactions twice a day and whenever someone pulls to refresh.
#
# Banks are connected from the app (any client: Banks -> Connect a bank),
# and their connections are kept in money's own data directory, so a
# restore from the backup below (or a move to another host) keeps every
# connection with nothing to relink. What stays here is the app's Plaid keys
# (dashboard.plaid.com; `ark sops money.yaml` to set money_plaid_client_id
# and money_plaid_secret), the environment, how much history a new bank
# brings, and when the importer runs.
{
  self,
  lib,
  config,
  ...
}:
let
  money = config.ark.money;
  ark = config.ark;
  # sivrad's headed browser (../sivrad/_chrome.nix), which money shares:
  # its DevTools, relayed to adam, and the page people see it on.
  sivrad = import ../sivrad/_container.nix;
  browser = {
    devtools = "http://${sivrad.localAddress}:${toString sivrad.cdpRelayPort}";
    page = "https://${ark.serviceDomain "sivrad-browser" ark.services.sivrad-browser}${sivrad.novncPrefix}";
  };
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
    };

    history = lib.mkOption {
      type = lib.types.ints.between 1 730;
      default = 90;
      description = "Days of history Plaid fetches when a bank is first connected.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06,18:00:00";
      description = "systemd OnCalendar expression for the import; twice a day by default.";
    };
  };

  config.ark.services.money = {
    # The app's Plaid keys: secrets/vars/money.yaml.
    secrets = {
      money_plaid_client_id.file = "money";
      money_plaid_secret.file = "money";
    };

    # money-server signs people in itself; the phones go through it.
    oidc.callbacks = [ "/auth/callback" ];

    # Everything money has, the budget and the banks' connections, every
    # night. The server stops for the copy so the log and the connections
    # are read as one moment; it is back in seconds, and the phones and
    # browsers redial. The service's dynamic user keeps its state behind
    # the /var/lib/money symlink.
    backup = {
      paths = [ "/var/lib/private/money" ];
      exclude = [
        "/var/lib/private/money/.npm"
        "/var/lib/private/money/.psql_history"
      ];
      stop = [ "money.service" ];
      schedule = "03:30";
    };

    nixos =
      {
        service,
        config,
        pkgs,
        ...
      }:
      let
        secret = name: config.sops.secrets.${name}.path;
      in
      {
        imports = [ self.inputs.koon-apps.nixosModules.money ];

        services.money = {
          enable = true;
          port = service.port;
          publicUrl = "https://${service.domain}";
          oidc = {
            inherit (service.oidc) issuer clientId clientSecretFile;
          };
          # The app's keys, as LoadCredentials read by systemd as root.
          plaid = {
            inherit (money.plaid) env;
            inherit (money) history;
            clientIdFile = secret "money_plaid_client_id";
            secretFile = secret "money_plaid_secret";
          };
          inherit (money) schedule;
          # Amazon's orders as receipts, signed in by the login given in the
          # app's Settings (kept in money's data directory, never here).
          amazon.package = pkgs.callPackage ./_amazon-orders.nix { };
          # Costco read on costco.com's own page in sivrad's browser, signed
          # in to there from its page; Amazon's sign-in challenge run there.
          inherit browser;
        };
      };
  };
}
