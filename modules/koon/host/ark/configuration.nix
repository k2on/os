{ self, ... }: {
  flake.nixosModules.koonArkConfiguration = { config, ... }: {
    imports = [
      ./_hardware-configuration.nix
      self.nixosModules.koonArkUser
      self.nixosModules.koonArkSops

      self.nixosModules.koonArkServiceAudio
      self.nixosModules.koonArkServiceAuth
      self.nixosModules.koonArkServiceGit
      self.nixosModules.koonArkServiceHome
      self.nixosModules.koonArkServicePhotos
      self.nixosModules.koonArkServiceRadicale
      self.nixosModules.koonArkServiceWakapi
    ];

    # Use the systemd-boot EFI boot loader.
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    networking.hostName = "ark";
    networking.nameservers = [ "8.8.8.8" "1.1.1.1" ];

    services.tailscale = {
      enable = true;
      useRoutingFeatures = "both";
      extraUpFlags = [ "--accept-dns=false" ];
    };

    # oauth.name = "KoonFamily";
    # oauth.secrets = import ./oauth-secrets.nix;

    security.sudo.wheelNeedsPassword = false;

    services.cloudflared = {
      enable = true;
      tunnels = {
        "91d31395-fbc7-45a1-ae13-148957b32ecd" = {
          credentialsFile = config.sops.secrets.tunnel-credentials.path;
          ingress = {
            "auth.koon.us" = "http://localhost:1411";
            "photos.koon.us" = "http://localhost:2283";
            "home.koon.us" = "http://localhost:8123";
            "docs.koon.us" = "http://localhost:3004";
            "git.koon.us" = "http://localhost:3000";
            "ssh.koon.us" = "ssh://localhost:2222";
            "audio.koon.us" = "http://localhost:8021";
            "radicale.koon.us" = "http://localhost:5232";
            "waka.koon.us" = "http://localhost:3006";
            # "ride.koon.us" = "http://localhost:3007";
            # "ride-api.koon.us" = "http://localhost:8080";

            "money.koon.us" = "http://localhost:3160";
            "zero.koon.us" = "http://localhost:4848";
            "money-api.koon.us" = "http://localhost:3161";

          };
          default = "http_status:404";
        };
      };
    };

    fileSystems."/mnt/hdd" = {
      device = "/dev/sdb";
      fsType = "ext4";
    };

    services.openssh.enable = true;

    networking.firewall.allowedTCPPorts = [ 8123 22 ];

    time.timeZone = "America/New_York";
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    system.stateVersion = "25.05"; # Did you read the comment?
  };
}
