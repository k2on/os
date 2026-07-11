{ self, ... }: {
  flake.nixosModules.koonMaxConfiguration = { pkgs, lib, modulesPath, ... }: {
    imports = [
      ./_hardware-configuration.nix

      self.nixosModules.commonUnstablePkgsOverlay

      self.nixosModules.commonFeatureLaptop

      self.nixosModules.commonFeatureEmail
      self.nixosModules.commonFeatureFont
      self.nixosModules.commonFeatureLocale
      self.nixosModules.commonFeatureYubikey

      self.nixosModules.commonFeatureHyprland

      self.nixosModules.koonFeatureTailscale

      self.nixosModules.koonMaxSops
      self.nixosModules.koonMaxUser
      self.nixosModules.koonMaxHomeManager
    ];

    # Use the systemd-boot EFI boot loader.
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;

    boot.m1n1CustomLogo = ../../../assets/logo.png;
    boot.binfmt.emulatedSystems = [ "x86_64-linux" ];

    hardware = {
      asahi = {
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

      prismlauncher

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

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    system.stateVersion = "25.05";
  };
}
