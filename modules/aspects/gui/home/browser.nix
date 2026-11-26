# The browser on every desktop: Zen, as the default for the web and mail
# links, with tracking and fingerprinting off and the same add-ons. What is
# in a person's tabs (containers, spaces, pins) is theirs (homes/<person>).
{ self, ... }:
{
  den.aspects.gui.provides.home.homeManager =
    { pkgs, ... }:
    {
      imports = [
        self.inputs.zen-browser.homeModules.beta
      ];

      xdg.mimeApps =
        let
          value =
            let
              browser = self.inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.beta; # or twilight
            in
            browser.meta.desktopFileName;

          associations = builtins.listToAttrs (
            map
              (name: {
                inherit name value;
              })
              [
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
              ]
          );
        in
        {
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

          Preferences = {
            "privacy.resistFingerprinting" = {
              Value = true;
              Status = "locked";
            };
            "privacy.resistFingerprinting.randomization.canvas.use_siphash" = {
              Value = true;
              Status = "locked";
            };
            "privacy.resistFingerprinting.randomization.daily_reset.enabled" = {
              Value = true;
              Status = "locked";
            };
            "privacy.resistFingerprinting.randomization.daily_reset.private.enabled" = {
              Value = true;
              Status = "locked";
            };
            "privacy.resistFingerprinting.block_mozAddonManager" = {
              Value = true;
              Status = "locked";
            };
          };
        };

        profiles.default =
          let
            # Add-ons not in the set above, each at one version and its
            # file's hash (addons.mozilla.org's API reports both:
            # /api/v5/addons/addon/<slug>/, current_version.file). To update
            # one, change its version, URL and hash together.
            inherit (self.inputs.firefox-addons.lib.${pkgs.stdenv.hostPlatform.system}) buildFirefoxXpiAddon;
            pinned = [
              # The default behaviour of ctrl+click, shift+click, cmd+click (on macOS) and middle-click when clicking on links is to open the link in a new tab (or new window in the case of shift).
              # This behaviour is sometimes broken by silly developers.
              (buildFirefoxXpiAddon {
                pname = "link-fixer";
                version = "1.11";
                addonId = "{18b670e2-67df-4b26-b9b0-34835d1f062a}";
                url = "https://addons.mozilla.org/firefox/downloads/file/3304205/link_fixer-1.11.xpi";
                sha256 = "8462f2f3f9fcb0506f0b86d093fd1e0535a6b9d1e417d09936902ee213beb481";
                meta = { };
              })
              # Linux has no built-in passkey authenticator, and some sites
              # won't offer passkeys without one: this says there
              # is one and lets a security key (the YubiKey) answer instead.
              # https://github.com/Buer-Nahida/Passkey-Dictator
              (buildFirefoxXpiAddon {
                pname = "passkey-dictator";
                version = "1.0.0";
                addonId = "passkey-dictator@nahida.im";
                url = "https://addons.mozilla.org/firefox/downloads/file/4982666/passkey_dictator-1.0.0.xpi";
                sha256 = "d79ec43efa05ed3071557593af211a8c2d032a12bb02ddbd3ce7456437809aca";
                meta = { };
              })
            ];
          in
          {
            # This is awesome :)
            # https://nur.nix-community.org/repos/rycee/
            extensions.packages =
              with self.inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system};
              [
                ublock-origin
                bitwarden
                istilldontcareaboutcookies
                darkreader
              ]
              ++ pinned;
          };
      };
    };
}
