{
  inputs,
  config,
  den,
  ...
}:
let
  # This folder's name: the host's, its flake output's and its hostname.
  name = baseNameOf ./.;
in
{
  den.hosts.x86_64-linux.${name} = {
    color = "#a6e3a1"; # light green
    dnsResolver = true;
    instantiate = inputs.nixpkgs-unstable.lib.nixosSystem;
  };

  den.aspects.${name} = {
    includes = with den.aspects; [
      service-audio
      service-cloud
      service-dash
      service-devices-apple
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
    ];

    nixos = {
      imports = [
        ./_hardware-configuration.nix
        config.flake.nixosModules.koonArkSops
        config.flake.nixosModules.acme
        config.flake.nixosModules.kanidm
        # What admin had, for whoever signs in now (aspects/defaults/login.nix).
        (
          { pkgs, ... }:
          {
            environment.systemPackages = with pkgs; [
              tree
              vim
              tmux
            ];
          }
        )
      ];

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      networking.nameservers = [
        "8.8.8.8"
        "1.1.1.1"
      ];

      services.tailscale = {
        useRoutingFeatures = "server";
        extraSetFlags = [ "--ssh=false" ];
      };

      fileSystems."/mnt/hdd" = {
        device = "/dev/sdb";
        fsType = "ext4";
      };

      # Every service's backup goes to both (lib/backups.nix). remote is
      # ephr's restic server.
      ark.backup.locations = {
        local.repository = "/mnt/hdd/restic";
        remote.repository = "rest:http://ephr:8000";
      };

      services.openssh.enable = true;

      networking.firewall.allowedTCPPorts = [
        8123
        22
        443
      ];

      time.timeZone = "America/Chicago";
      nix.settings = {
        # This host builds its own system with 4 cores and 8 GB, most of
        # it taken by what it runs. Unbounded, a large build (the sivrad
        # container's Hermes tree) thrashed it into silence for an hour.
        max-jobs = 1;
        cores = 2;
        # What k2on/apps' CI built (harken's server, its web client, arkdb:
        # the build workflow's `server` job), so a deploy of harken
        # substitutes them rather than compiling them here.
        extra-substituters = [ "https://k2on.cachix.org" ];
        extra-trusted-public-keys = [ "k2on.cachix.org-1:oI4Db0uW5ER+s4Te/MrXSmjWUWkOc9rmKdzsgUDxQP8=" ];
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
