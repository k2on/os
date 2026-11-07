# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# ephr's own setup, from the /etc/nixos/configuration.nix it was installed
# with.
{ pkgs, ... }:
{
  # Use the systemd-boot EFI boot loader. Asahi has no writable EFI
  # variables (as on cale).
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.systemd-boot.graceful = true;

  networking.wireless.iwd = {
    enable = true;
    settings.General.EnableNetworkConfiguration = true;
  };

  # Who signs in, and how: aspects/login.nix (Kanidm, and root over ssh).
  environment.systemPackages = with pkgs; [
    tree
    vim
  ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  services.tailscale.enable = true;

  services.restic.server = {
    enable = true;
    extraFlags = [ "--no-auth" ];
  };

  services.openssh.enable = true;

  system.stateVersion = "25.11";
}
