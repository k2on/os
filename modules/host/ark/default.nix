{ inputs, config, den, ... }: {
  den.hosts.x86_64-linux.ark = {
    instantiate = inputs.nixpkgs-unstable.lib.nixosSystem;
  };

  den.aspects.ark = {
    includes = with den.aspects; [
      service-audio
      service-auth
      service-cloud
      service-git
      service-home
      # service-id
      service-jellyfin
      service-photos
      service-radicale
      service-waka
      # ark-tunnel
      ark-nginx
    ];

    nixos = {
      imports = [
        ./_hardware-configuration.nix
        inputs.sops-nix.nixosModules.sops
        config.flake.nixosModules.koonArkUser
        config.flake.nixosModules.koonArkSops
        config.flake.nixosModules.acme
        config.flake.nixosModules.kanidm
      ];

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      networking.hostName = "ark";
      networking.nameservers = [ "8.8.8.8" "1.1.1.1" ];

      services.tailscale = {
        enable = true;
        useRoutingFeatures = "server";
        extraSetFlags = [ "--ssh=false" ];
      };

      security.sudo.wheelNeedsPassword = false;

      fileSystems."/mnt/hdd" = {
        device = "/dev/sdb";
        fsType = "ext4";
      };

      services.openssh.enable = true;

      networking.firewall.allowedTCPPorts = [ 8123 22 443 ];

      time.timeZone = "America/Chicago";
      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      system.stateVersion = "25.05"; # Did you read the comment?
    };
  };
}
