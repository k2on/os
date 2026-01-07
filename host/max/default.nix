{ pkgs, pkgs-unstable, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../common/core/default.nix
    ./user.nix
    ./work.nix
    ./sops.nix

    ../common/optional/desktop/hyprland.nix

    ../common/optional/yubikey.nix

    ../common/optional/browser.nix


    ../common/optional/locale.nix
    ../common/optional/email.nix

    ./proton.nix
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  boot.m1n1CustomLogo = ../../assets/logo.png;

  hardware = {
    asahi = {
      peripheralFirmwareDirectory = ./firmware;
      setupAsahiSound = true;
    };
  };

  networking.networkmanager.enable = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  services.tailscale.enable = true;

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

    # mpc
    gurk-rs
    libreoffice-qt
    # ncmpcpp

    pkgs-unstable.signal-desktop-bin
    gnupg

    (pass.withExtensions (exts: [ exts.pass-otp ]))

    pinentry-curses
    pinentry-qt

    fzf
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
  ];

  programs.zsh.enable = true;

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-qt;
    enableSSHSupport = true;
  };

  system.stateVersion = "25.05";
}
