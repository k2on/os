{ ... }: {
  flake.homeModules.commonFeatureImageViewer = { pkgs, ... }: {
    xdg.desktopEntries.imv = {
      name = "imv";
      exec = "${pkgs.imv}/bin/imv %F";
      icon = "imv";
    };

    xdg.mimeApps = let
      value = "imv.desktop";

      associations = builtins.listToAttrs (map (name: {
          inherit name value;
        }) [
          "image/png"
          "image/jpeg"
          "image/gif"
          "image/bmp"
          "image/webp"
        ]);
    in {
      enable = true;
      associations.added = associations;
      defaultApplications = associations;
    };
  };
}
