{ config, lib, pkgs, ... }: {
  imports = [
    ./hardware-configuration.nix
    ./options.nix
    ../common/core/default.nix
    ./user.nix
    ./sops.nix

    ./service/audio.nix
    ./service/auth.nix
    ./service/docs.nix
    ./service/git.nix
    ./service/home.nix
    ./service/photos.nix
    ./service/radicale.nix
    ./service/wakapi.nix
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

  oauth.name = "KoonFamily";
  oauth.secrets = import ./oauth-secrets.nix;

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

  system.stateVersion = "25.05"; # Did you read the comment?
}

