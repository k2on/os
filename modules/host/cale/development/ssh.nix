{ ... }: {
  flake.homeModules.koonMaxSsh = { ... }: {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      matchBlocks = {
        "*" = {
          addKeysToAgent = "yes";
        };
        "m1" = {
          host = "m1";
          user = "admin";
        };
        "ark" = {
          host = "ark";
          user = "admin";
        };
        "git" = {
          host = "github.com";
          user = "git";
          identityFile = [
            "~/.ssh/id_maxkey"
          ];
        };
      };
    };

    home.file = {
      ".ssh/id_maxkey.pub".source = ./id_maxkey.pub;
    };
  };
}
