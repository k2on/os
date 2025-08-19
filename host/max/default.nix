{ pkgs, config, pkgs-unstable, ... }:
let
  openconnect-sso-src = builtins.fetchTree {
    type = "github";
    owner = "k2on";
    repo = "openconnect-sso";
    rev = "9d4f61e5c8ccca420ffa87d46c96c17d64fbfb0b";
    narHash = "sha256-ENt4/+9Bll70+BkH0Scej02edLi9SNkvBfyvjxUv83w=";
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../common/core/default.nix
    ./user.nix
    ./work.nix
    ./sops.nix

    ../common/optional/yubikey.nix

    ../common/optional/browser.nix
    ../common/optional/desktop.nix
    ../common/optional/fonts.nix
    ../common/optional/locale.nix
    ../common/optional/email.nix

    ./zero-cache.nix
  ];
  services.zero-cache.enable = false;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  boot.m1n1CustomLogo = ../../assets/logo.png;

  hardware = {
    asahi = {
      peripheralFirmwareDirectory = ./firmware;
      useExperimentalGPUDriver = true;
      experimentalGPUInstallMode = "replace";
      setupAsahiSound = true;
    };
  };

  # networking.hostName = "nixos"; # Define your hostname.
  # Pick only one of the below networking options.
  networking.networkmanager.enable =
    true; # Easiest to use and most distros use this by default.

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  environment.variables = {
    XDG_DATA_HOME = "/home/max/.local/share";
    GSK_RENDERER = "ngl";
    EDITOR = "nvim";
  };

  programs.wireshark.enable = true;
  programs.adb.enable = true;

  programs.kdeconnect.enable = true;
  environment.systemPackages = with pkgs; [
    vim
    git
    wget

    # mpc
    gurk-rs
    libreoffice-qt
    # ncmpcpp

    brave

    signal-desktop
    gnupg

    (pass.withExtensions (exts: [ exts.pass-otp ]))

    pinentry
    pinentry-curses
    pinentry-qt

    zathura

    fzf
    ffmpeg
    ripgrep
    unzip
    zbar
    tt
    sc-im
    libqalculate
    librespeed-cli

    tea

    kubectl
    cloudflared
    # gcc

    prismlauncher

    gimp
    inkscape

    wireshark

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

    (pkgs.callPackage "${openconnect-sso-src}/nix" {}).openconnect-sso
  ];

  programs.zsh.enable = true;

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-qt;
    enableSSHSupport = true;
  };

  system.stateVersion = "25.05";

}
