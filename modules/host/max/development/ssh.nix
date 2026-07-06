{ ... }: {
  flake.homeModules.koonMaxSsh = { pkgs, ... }: {
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
        "ssh.koon.us" = {
          host = "ssh.koon.us";
          user = "git";
          proxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
          serverAliveInterval = 30;
          serverAliveCountMax = 10;
          # TCPKeepAlive="yes";
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
