# Booting: m1n1, then systemd-boot. Asahi has no writable EFI variables.
{ ... }:
{
  den.aspects.asahi.nixos = {
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.systemd-boot.graceful = true; # passes --graceful, ignores EFI-variable errors

    boot.m1n1CustomLogo = ../../../assets/logo.png;
  };
}
