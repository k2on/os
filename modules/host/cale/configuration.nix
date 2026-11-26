{ self, ... }:
{
  flake.nixosModules.koonMaxConfiguration =
    {
      pkgs,
      modulesPath,
      ...
    }:
    {
      imports = [
        self.nixosModules.koonMaxUser
      ];

      boot.binfmt.emulatedSystems = [ "x86_64-linux" ];

      networking.networkmanager.plugins = with pkgs; [
        networkmanager-openconnect
      ];

      # The machine's own tools; the person's programs are their home's
      # (./apps.nix).
      environment.systemPackages = with pkgs; [
        networkmanager

        vim
        git
        wget
        file

        gnupg
        pinentry-curses
        pinentry-qt

        gparted

        (writeShellScriptBin "battery-graph" ''
          ${coreutils}/bin/tail -n 20 /var/lib/upower/history-charge-bq40z651-69-F8Y3262H468Q1LTA1.dat | ${coreutils}/bin/cut -f1,2 | RUBYOPT='-W0' ${youplot}/bin/uplot line -w 70
        '')
      ];

      programs.zsh.enable = true;

      programs.gnupg.agent = {
        enable = true;
        pinentryPackage = pkgs.pinentry-qt;
        enableSSHSupport = true;
      };

      # When memory runs out (aspects/defaults/memory.nix), rather a build or
      # a transcription than anything the session runs on.
      services.earlyoom = {
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
