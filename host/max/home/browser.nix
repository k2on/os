{
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
