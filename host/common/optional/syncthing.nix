{ ... }:
{
  services.syncthing = {
    enable = true;
    openDefaultPorts = true;

    settings = {
      devices = {
        "phone" = { id = "DBTMZ3P-VONFNYH-LDDNIO3-ZZ2TKO5-QFVV5D4-W4FMV67-HUTIJQB-UHNF3QM"; };
      };

      folders = {
        "Music" = {
          path = "/home/max/media/music";
          devices = [ "phone" ];
        };
      };
    };
  };
}
