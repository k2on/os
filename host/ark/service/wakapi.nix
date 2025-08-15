{ config, ... }:
{

  nixpkgs.overlays = [
    (final: prev: {
      wakapi = prev.wakapi.overrideAttrs (oldAttrs: rec {
        src = final.fetchFromGitHub {
          owner = "k2on";
          repo = "wakapi";
          rev = "theming";
          # hash = "";
          hash = "sha256-mbQ2cA9tbuDA5OXEP+qVfsrBC90budAzWE7x4oN6ypY=";
        };
        # vendorHash = final.lib.fakeHash;
        vendorHash = "sha256-lb6u9NQbB3bizIRbCRaB7Ngv9T5mAYtSl+g13gL7VEU=";
      });
    })
  ];

  services.wakapi = {
    enable = true;
    passwordSaltFile = config.sops.secrets."waka-password-salt".path;
    settings = {
      server.port = 3006;
      app.avatar_url_template = "https://auth.koon.us/api/users/fbffa48a-faf7-4230-a89f-0da184f5948c/profile-picture.png";
    };
  };
}
