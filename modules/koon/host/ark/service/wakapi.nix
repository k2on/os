{ ... }: {
  flake.nixosModules.koonArkServiceWakapi = { config, ... }: {
    nixpkgs.overlays = [
      (final: prev: let
          version = "2.15.0";
        in {

        wakapi = (prev.buildGoModule.override { go = prev.go_1_25; }) {
          pname = "wakapi";
          version = version;

          src = final.fetchFromGitHub {
            owner = "k2on";
            repo = "wakapi";
            rev = "koon-fork";
            hash = "sha256-FYGtoJmbqUD02/JKvON1RqpjkrDkAOkfPwMAUZ2MSE4=";
          };

          vendorHash = "sha256-912x6LwitYXdjWpP75Xoc56JXadeLQZuESSyLoaJcU0=";

          excludedPackages = [ "scripts" ];

          postPatch = ''echo ${version} > version.txt'';

          ldflags = [ "-s" "-w" ];

          passthru = {
            nixos = prev.nixosTests.wakapi;
            updateScript = prev.nix-update-script { };
          };

          meta = prev.wakapi.meta // {
            version = version;
            mainProgram = "wakapi";
          };
        };

      })
    ];

    services.wakapi = {
      enable = true;
      # passwordSaltFile = config.sops.secrets."waka-password-salt".path;
      settings = {
        server.port = 3006;
        app.avatar_url_template = "https://auth.koon.us/api/users/fbffa48a-faf7-4230-a89f-0da184f5948c/profile-picture.png";
      };
    };
  };
}
