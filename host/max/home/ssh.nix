{ ... }: 
{
  programs.ssh = {
    enable = true;

    extraConfig = ''
      Host m1
              HostName m1
              User admin

      Host surface
              HostName surface
              User admin

      Host ark
              HostName ark
              User admin

      Host pi
              HostName 192.168.0.143
              User admin

      Host ssh.koon.us
              HostName ssh.koon.us
              ProxyCommand cloudflared access ssh --hostname %h
              User git

      AddKeysToAgent yes
    '';

    matchBlocks = {
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
    ".ssh/id_maxkey.pub".source = ../keys/id_maxkey.pub;
  };
}
