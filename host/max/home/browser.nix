{ config, zen-browser, system, pkgs, firefox-addons, ... }:
{
  xdg.mimeApps = let
    value = let
      browser = zen-browser.packages.${system}.beta; # or twilight
    in
      browser.meta.desktopFileName;

    associations = builtins.listToAttrs (map (name: {
        inherit name value;
      }) [
        "application/x-extension-shtml"
        "application/x-extension-xhtml"
        "application/x-extension-html"
        "application/x-extension-xht"
        "application/x-extension-htm"
        "x-scheme-handler/unknown"
        "x-scheme-handler/mailto"
        "x-scheme-handler/chrome"
        "x-scheme-handler/about"
        "x-scheme-handler/https"
        "x-scheme-handler/http"
        "application/xhtml+xml"
        "application/json"
        "text/plain"
        "text/html"
      ]);
  in {
    enable = true;
    associations.added = associations;
    defaultApplications = associations;
  };

  programs.zen-browser = {
    enable = true;

    policies = {
      AutofillAddressEnabled = false;
      AutofillCreditCardEnabled = false;
      DisableAppUpdate = true;
      DisableFeedbackCommands = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      DisableTelemetry = true;
      DontCheckDefaultBrowser = true;
      NoDefaultBookmarks = true;
      OfferToSaveLogins = false;
      EnableTrackingProtection = {
        Value = true;
        Locked = true;
        Cryptomining = true;
        Fingerprinting = true;
      };


      # ID's can be collected from this command:
      # nix run github:tupakkatapa/mozid -- "https://addons.mozilla.org/en-US/firefox/addon/<example>/"
      ExtensionSettings = {
        # The default behaviour of ctrl+click, shift+click, cmd+click (on macOS) and middle-click when clicking on links is to open the link in a new tab (or new window in the case of shift).
        # This behaviour is sometimes broken by silly developers.
        "{18b670e2-67df-4b26-b9b0-34835d1f062a}" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/link-fixer/latest.xpi";
          installation_mode = "force_installed";
        };
      };
    };

    profiles.default = let
      containers = {
        Personal = {
          color = "yellow";
          icon = "circle";
          id = 1;
        };
        School = {
          color = "red";
          icon = "fruit";
          id = 2;
        };
        Work = {
          color = "blue";
          icon = "briefcase";
          id = 3;
        };
      };
      spaces = {
        Personal = {
          id = "c6de089c-410d-4206-961d-ab11f988d40a";
          icon = "⭐";
          container = containers."Personal".id;
          position = 1000;
        };
        School = {
          id = "78aabdad-8aae-4fe0-8ff0-2a0c6c4ccc24";
          icon = "🍎";
          container = containers."School".id;
          position = 2000;
        };
        Work = {
          id = "cdd10fab-4fc5-494b-9041-325e5759195b";
          icon = "💼";
          container = containers."Work".id;
          position = 3000;
        };
      };
      pins = {
        # Personal Pins
        "Proton Mail" = {
          id = "d9942e0a-0997-418d-b357-91727300d184";
          container = containers.Personal.id;
          url = "https://mail.proton.me";
          isEssential = true;
          position = 1;
        };
        "Proton Calendar" = {
          id = "6557e03f-c0ab-4656-ac94-acfb1fe19f3c";
          container = containers.Personal.id;
          url = "https://calendar.proton.me";
          isEssential = true;
          position = 2;
        };
        "YNAB" = {
          id = "10cb5609-fcd5-4ed6-a48d-24eb22f2d624";
          container = containers.Personal.id;
          url = "https://app.ynab.com";
          isEssential = true;
          position = 3;
        };

        # # School Pins
        # "Canvas" = {
        #   id = "cfbdc143-6a16-46d7-b33e-e9c964725e59";
        #   workspace = spaces.School.id;
        #   container = containers.School.id;
        #   url = "https://clemson.instructure.com/calendar";
        #   isEssential = true;
        #   position = 104;
        # };
      };
    in {
      containersForce = true;
      spacesForce = true;
      pinsForce = true;
      inherit containers spaces pins;

      # This is awesome :)
      # https://nur.nix-community.org/repos/rycee/
      extensions.packages = with firefox-addons.packages.${pkgs.stdenv.hostPlatform.system}; [
        ublock-origin
        proton-pass
        istilldontcareaboutcookies
        better-canvas
        darkreader
      ];
    };
  };
}
