{ self, config, ... }:
{
  flake.nixosModules.koonMaxConfiguration =
    {
      pkgs,
      lib,
      modulesPath,
      ...
    }:
    {
      imports = [
        ./_hardware-configuration.nix

        self.nixosModules.commonUnstablePkgsOverlay

        self.nixosModules.commonFeatureLaptop

        self.nixosModules.commonFeatureEmail
        self.nixosModules.commonFeatureFont
        self.nixosModules.commonFeatureYubikey

        self.nixosModules.commonFeatureCosmic

        self.nixosModules.koonFeatureTailscale

        self.nixosModules.koonMaxSops
        self.nixosModules.koonMaxUser
        self.nixosModules.koonMaxHomeManager
      ];

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = false;
      boot.loader.systemd-boot.graceful = true; # passes --graceful, ignores EFI-variable errors

      boot.m1n1CustomLogo = ../../../assets/logo.png;
      boot.binfmt.emulatedSystems = [ "x86_64-linux" ];

      hardware = {
        asahi = {
          enable = true;
          peripheralFirmwareDirectory = ./firmware;
          setupAsahiSound = true;
        };

        graphics = {
          enable = true;
          extraPackages = with pkgs; [
            mesa.opencl
          ];
        };
      };

      networking.networkmanager = {
        enable = true;
        plugins = with pkgs; [
          networkmanager-openconnect
        ];
      };

      hardware.bluetooth = {
        enable = true;
        powerOnBoot = true;
      };

      # PipeWire < 1.4.10 has a bug where the Asahi DSP speaker sink comes up
      # with its volume locked at 100% after boot and can't be changed until
      # some audio has played once (upstream
      # https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/4900,
      # AsahiLinux/asahi-audio#73). nixos-25.11 ships 1.4.9, so pull PipeWire
      # and its matching WirePlumber from unstable where the fix is present.
      services.pipewire.package = pkgs.pkgs-unstable.pipewire;
      services.pipewire.wireplumber.package = pkgs.pkgs-unstable.wireplumber;

      # The internal microphone hangs off a second ALSA card (the AOP
      # "High-Power Audio Interface", alsa_card.platform-audio.*). asahi-audio
      # only spawns the j414-mic DSP chain -- and with it the only usable
      # internal mic source -- while that card sits in its HiFi profile.
      # WirePlumber restores whichever profile it last saved in
      # ~/.local/state/wireplumber/default-profile, so a single stray "off"
      # there silently kills the mic on every subsequent boot. Refuse to
      # restore an "off" profile for this one card; WirePlumber then falls back
      # to picking HiFi itself. Bluetooth profile restore is unaffected.
      services.pipewire.wireplumber.extraConfig."51-asahi-internal-mic" = {
        "monitor.alsa.rules" = [
          {
            matches = [ { "device.name" = "~alsa_card.platform-audio.*"; } ];
            actions.update-props."session.dont-restore-off-profile" = true;
          }
        ];
      };

      # WirePlumber exposes the AirPods as a virtual mic and, the moment
      # anything opens it, flips the card from A2DP to HSP/HFP -- choppy,
      # phone-quality audio and an extra RFCOMM link that keeps dropping.
      # Stay on A2DP; switch to the headset profile by hand for calls.
      services.pipewire.wireplumber.extraConfig."52-bluetooth-no-autoswitch" = {
        "wireplumber.settings"."bluetooth.autoswitch-to-headset-profile" = false;
      };

      environment.variables = {
        XDG_DATA_HOME = "/home/max/.local/share";
        GSK_RENDERER = "ngl";
        EDITOR = "nvim";
      };
      environment.sessionVariables.NIXOS_OZONE_WL = "1";

      programs.kdeconnect.enable = true;

      environment.systemPackages = with pkgs; [
        networkmanager

        vim
        git
        wget
        file
        just

        libreoffice-qt

        pkgs-unstable.signal-desktop
        pkgs-unstable.gurk-rs

        gnupg

        (pass.withExtensions (exts: [ exts.pass-otp ]))

        pinentry-curses
        pinentry-qt

        fzf
        zip
        jq
        ffmpeg
        ripgrep
        unzip
        zbar
        tt
        sc-im
        libqalculate
        librespeed-cli

        wl-clipboard

        gparted

        tea
        gh

        glow
        delta

        cloudflared
        # gcc

        pkgs-unstable.claude-code

        (pkgs.chromium.override { enableWideVine = true; })

        gimp
        inkscape

        # arm support
        pkgs-unstable.sparrow

        (writeShellScriptBin "radio" ''
          list="
          WIOP http://s4.yesstreaming.net:7119/;audio.mp3
          FamilyAlter https://usa17.fastcast4u.com/proxy/roloffev?mp=/1
          "

          choice=$(echo "$list" | awk '{print $1}' | ${fzf}/bin/fzf)

          if [[ -n "$choice" ]]; then
            url=$(echo "$list" | awk -v name="$choice" '$1==name {print $2}')
            ${mpg123}/bin/mpg123 "$url"
          fi
        '')

        (pkgs.writeShellScriptBin "battery-graph" ''
          ${pkgs.coreutils}/bin/tail -n 20 /var/lib/upower/history-charge-bq40z651-69-F8Y3262H468Q1LTA1.dat | ${pkgs.coreutils}/bin/cut -f1,2 | RUBYOPT='-W0' ${pkgs.youplot}/bin/uplot line -w 70
        '')

        (pkgs.writeShellScriptBin "ocr-clip" ''
          ${pkgs.grimblast}/bin/grimblast -f save area - | ${pkgs.tesseract}/bin/tesseract stdin stdout | ${pkgs.wl-clipboard}/bin/wl-copy
        '')

        # harken's and money's desktop apps (koon-apps' iced clients), each
        # on ark's server.
        (pkgs.writeShellScriptBin "harken" ''
          exec ${
            self.inputs.koon-apps.packages.${pkgs.stdenv.hostPlatform.system}.harken-iced
          }/bin/harken-iced --server https://harken.${config.ark.mainDomain} "$@"
        '')
        (pkgs.makeDesktopItem {
          name = "harken";
          desktopName = "Harken";
          exec = "harken";
          categories = [
            "AudioVideo"
            "Audio"
          ];
        })

        (pkgs.writeShellScriptBin "money" ''
          exec ${
            self.inputs.koon-apps.packages.${pkgs.stdenv.hostPlatform.system}.money-iced
          }/bin/money-iced --server https://money.${config.ark.mainDomain} "$@"
        '')
        (pkgs.makeDesktopItem {
          name = "money";
          desktopName = "Money";
          exec = "money";
          categories = [
            "Office"
            "Finance"
          ];
        })
      ];

      programs.zsh.enable = true;

      programs.gnupg.agent = {
        enable = true;
        pinentryPackage = pkgs.pinentry-qt;
        enableSSHSupport = true;
      };

      networking.extraHosts = "127.0.0.1 s3";

      # transparent.nvim (used by neovim) ships no license file, so nixpkgs
      # marks it unfree as of 26.05. Allow just this package.
      nixpkgs.config.allowUnfreePredicate =
        pkg:
        builtins.elem (lib.getName pkg) [
          "chromium"
          "chromium-unwrapped"
          "widevine-cdm"
          "transparent.nvim"
        ];

      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Deduplicate the store. Garbage collection is every host's
      # (aspects/gc.nix).
      nix.settings.auto-optimise-store = true;

      # Compressed swap in RAM: with no swap at all, a big link and whisper
      # at once ran memory out and the kernel's OOM killer took the
      # session's own D-Bus and systemd --user with the build, leaving the
      # desktop up but its brightness, volume and shortcut keys dead until
      # a reboot. Half of RAM, zstd.
      zramSwap = {
        enable = true;
        memoryPercent = 50;
      };
      # When memory runs out anyway, kill the biggest process early, and
      # rather a build or a transcription than anything the session runs on.
      services.earlyoom = {
        enable = true;
        freeMemThreshold = 5;
        freeSwapThreshold = 10;
        extraArgs = [
          "--prefer"
          "^(ld|ld\\.lld|rustc|cc1plus|cargo|whisper-cli|node|nix)$"
          "--avoid"
          "^(systemd|dbus-broker.*|dbus-daemon|pipewire.*|wireplumber|cosmic-.*|Xwayland)$"
        ];
      };

      system.stateVersion = "25.05";
    };
}
