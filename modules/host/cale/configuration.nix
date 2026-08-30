{ self, ... }:
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
        self.nixosModules.commonFeatureLocale
        self.nixosModules.commonFeatureYubikey

        self.nixosModules.commonFeatureCosmic

        self.nixosModules.koonFeatureTailscale

        self.nixosModules.koonMaxSops
        self.nixosModules.koonMaxUser
        self.nixosModules.koonMaxHomeManager
      ];

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.systemd-boot.configurationLimit = 5;
      boot.loader.efi.canTouchEfiVariables = false;

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

        gparted

        tea

        cloudflared
        # gcc

        pkgs-unstable.claude-code

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
        pkg: builtins.elem (lib.getName pkg) [ "transparent.nvim" ];

      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Deduplicate the store and collect garbage weekly, keeping only the
      # generations still referenced within the last 5 boot entries above.
      nix.settings.auto-optimise-store = true;
      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };

      system.stateVersion = "25.05";
    };
}
