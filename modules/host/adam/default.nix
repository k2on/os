{
  inputs,
  config,
  den,
  ...
}:
{
  den.hosts.x86_64-linux.adam = {
    instantiate = inputs.nixpkgs-unstable.lib.nixosSystem;
  };

  den.aspects.adam = {
    includes = with den.aspects; [
      service-audio
      service-cloud
      service-git
      service-harken
      service-home
      service-money
      service-pass
      service-photos
      service-radicale
      service-waka
      ark-nginx
      service-sivrad
      service-sivrad-browser
      tailnet
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
      networking.nameservers = [
        "8.8.8.8"
        "1.1.1.1"
      ];

      services.tailscale = {
        useRoutingFeatures = "server";
        extraSetFlags = [ "--ssh=false" ];
      };

      security.sudo.wheelNeedsPassword = false;

      fileSystems."/mnt/hdd" = {
        device = "/dev/sdb";
        fsType = "ext4";
      };

      services.openssh.enable = true;

      networking.firewall.allowedTCPPorts = [
        8123
        22
        443
      ];

      time.timeZone = "America/Chicago";
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        # This host builds its own system with 4 cores and 8 GB, most of
        # it taken by what it runs. Unbounded, a large build (the sivrad
        # container's Hermes tree) thrashed it into silence for an hour.
        max-jobs = 1;
        cores = 2;
      };
      # Compressed swap in RAM: no swap at all meant memory pressure had
      # nowhere to go but the page cache, and the host stopped answering
      # instead of slowing down. Half of RAM, zstd.
      zramSwap = {
        enable = true;
        memoryPercent = 50;
      };
      # When memory runs out anyway, kill the biggest process (a build)
      # early, before the kernel spends an hour thrashing; the kernel's own
      # OOM killer only wakes once there is nothing left to evict.
      services.earlyoom = {
        enable = true;
        freeMemThreshold = 5;
        freeSwapThreshold = 10;
      };
      # And when the host stops responding altogether, with nobody near
      # it: systemd pets the hardware watchdog; a hang of over two minutes
      # reboots into the current generation.
      systemd.watchdog = {
        runtimeTime = "2min";
        rebootTime = "5min";
      };

      system.stateVersion = "25.05"; # Did you read the comment?
    };
  };
}
