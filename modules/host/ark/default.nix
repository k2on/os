{ inputs, config, den, ... }: {
  den.hosts.x86_64-linux.ark = {
    instantiate = inputs.nixpkgs-unstable.lib.nixosSystem;
  };

  den.aspects.ark = {
    includes = with den.aspects; [
      service-audio
      service-auth
      service-git
      service-home
      service-jellyfin
      service-photos
      service-radicale
      service-waka
      ark-tunnel
    ];

    nixos = {
      imports = [
        ./_hardware-configuration.nix
        inputs.sops-nix.nixosModules.sops
        config.flake.nixosModules.koonArkUser
        config.flake.nixosModules.koonArkSops
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

      security.sudo.wheelNeedsPassword = false;

      fileSystems."/mnt/hdd" = {
        device = "/dev/sdb";
        fsType = "ext4";
      };

      services.openssh.enable = true;

      networking.firewall.allowedTCPPorts = [ 8123 22 ];

      time.timeZone = "America/Chicago";
      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      system.stateVersion = "25.05"; # Did you read the comment?
    };
  };
}
