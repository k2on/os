{ config, pkgs, firefox-addons, ... }:
{
  xdg.mimeApps = {
    enable = true;

    defaultApplications = {
      "x-scheme-handler/http" = "zen-beta.desktop";
      "x-scheme-handler/https" = "zen-beta.desktop";
      "x-scheme-handler/chrome" = "zen-beta.desktop";
      "text/html" = "zen-beta.desktop";
      "application/x-extension-htm" = "zen-beta.desktop";
      "application/x-extension-html" = "zen-beta.desktop";
      "application/x-extension-shtml" = "zen-beta.desktop";
      "application/xhtml+xml" = "zen-beta.desktop";
      "application/x-extension-xhtml" = "zen-beta.desktop";
      "application/x-extension-xht" = "zen-beta.desktop";
    };

    associations.added = {
      "x-scheme-handler/http" = [ "zen-beta.desktop" ];
      "x-scheme-handler/https" = [ "zen-beta.desktop" ];
      "x-scheme-handler/chrome" = [ "zen-beta.desktop" ];
      "text/html" = [ "zen-beta.desktop" ];
      "application/x-extension-htm" = [ "zen-beta.desktop" ];
      "application/x-extension-html" = [ "zen-beta.desktop" ];
      "application/x-extension-shtml" = [ "zen-beta.desktop" ];
      "application/xhtml+xml" = [ "zen-beta.desktop" ];
      "application/x-extension-xhtml" = [ "zen-beta.desktop" ];
      "application/x-extension-xht" = [ "zen-beta.desktop" ];
    };
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
      ];
    };
  };

  programs.firefox = {
    enable = true;
    profiles = {
      personal = {
        id = 0;
        name = "1. Personal";
        isDefault = true;
        settings = {
          "browser.search.defaultenginename" = "ddg";
          "browser.search.order.1" = "ddg";

          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
        };
        search = {
          force = true;
          default = "ddg";
          order = [ "ddg" "google" ];
        };
        userChrome = builtins.readFile ./browser/userChrome.css;
      };
      work = {
        id = 1;
        name = "2. Work";
        settings = {
          "browser.search.defaultenginename" = "ddg";
          "browser.search.order.1" = "ddg";

          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
        };
        search = {
          force = true;
          default = "ddg";
          order = [ "ddg" "google" ];
        };
        userChrome = builtins.readFile ./browser/userChrome.css;
      };
      school = {
        id = 2;
        name = "3. School";
        settings = {
          "browser.search.defaultenginename" = "ddg";
          "browser.search.order.1" = "ddg";

          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
        };
        search = {
          force = true;
          default = "ddg";
          order = [ "ddg" "google" ];
        };
        userChrome = builtins.readFile ./browser/userChrome.css;
      };

    };
  };
}
