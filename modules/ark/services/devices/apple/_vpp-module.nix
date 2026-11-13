# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# services.apple-vpp: device licenses for App Store apps, from Apple
# Business Manager's Apps and Books, assigned declaratively. Apps and Books
# has the licenses ("bought" there, free apps included, for one location);
# its content token for that location lets this assign them to devices by
# serial number, so an MDM can install the app with no Apple ID
# (com.apple.configuration.app.managed with a Device license).
#
# apple-vpp-sync asks Apple to associate every app in `assignments` with its
# serial numbers on every start and every change, and waits for the result.
# Associating what is already associated changes nothing. A license is not
# taken back when a serial number is removed here: do that in ABM.
#
# Apple's App, Book, and Subscription Management API, version 2:
# developer.apple.com/documentation/devicemanagement/app-book-and-subscription-management
#
# Written with nothing of ark in it, to go to nixpkgs one day.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.apple-vpp;
  api = "https://vpp.itunes.apple.com/mdm/v2";

  assignments = pkgs.writeText "apple-vpp-assignments.json" (
    builtins.toJSON (
      lib.mapAttrsToList (adamId: serialNumbers: { inherit adamId serialNumbers; }) (
        lib.filterAttrs (_: s: s != [ ]) cfg.assignments
      )
    )
  );

  sync = pkgs.writeShellApplication {
    name = "apple-vpp-sync";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = ''
      # The content token as ABM gives it (the .vpptoken file), as the bearer.
      token=$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/token")
      call() { curl -sS --fail-with-body -H "Authorization: Bearer $token" "$@"; }

      jq -c '.[]' ${assignments} | while read -r a; do
        id=$(jq -r .adamId <<<"$a")
        event=$(jq -c '{assets: [{adamId, pricingParam: "STDQ"}], serialNumbers}' <<<"$a" \
          | call -X POST -H 'Content-Type: application/json' --data-binary @- ${api}/assets/associate \
          | jq -er .eventId)
        # Apple does it in the background; it takes seconds.
        for _ in $(seq 60); do
          status=$(call "${api}/status?eventId=$event")
          [ "$(jq -r .eventStatus <<<"$status")" = PENDING ] || break
          sleep 5
        done
        echo "$id: $(jq -c . <<<"$status")"
      done
    '';
  };
in
{
  options.services.apple-vpp = {
    enable = lib.mkEnableOption "assigning Apps and Books licenses to devices";

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "The content token for the Apps and Books location (the .vpptoken download).";
    };

    assignments = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        "1470499037" = [ "KN2QHVKC9J" ];
      };
      description = "Serial numbers to give a device license, by the app's App Store ID (adamId).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.apple-vpp-sync = {
      description = "Assign Apps and Books licenses to devices";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      restartTriggers = [ sync ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        LoadCredential = [ "token:${cfg.tokenFile}" ];
        ExecStart = lib.getExe sync;
        # Apple's API may be away for a moment.
        Restart = "on-failure";
        RestartSec = 60;
      };
    };
  };
}
