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

        self.nixosModules.commonFeatureEmail

        self.nixosModules.koonMaxSops
        self.nixosModules.koonMaxUser
        self.nixosModules.koonMaxHomeManager
      ];

      boot.binfmt.emulatedSystems = [ "x86_64-linux" ];

      networking.networkmanager.plugins = with pkgs; [
        networkmanager-openconnect
      ];

      environment.variables = {
        XDG_DATA_HOME = "/home/max/.local/share";
        EDITOR = "nvim";
      };

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
      # (aspects/defaults/gc.nix).
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
