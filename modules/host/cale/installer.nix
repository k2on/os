# An installer ISO for cale: nixos-apple-silicon's installer with ZFS turned
# back on (it leaves ZFS out, since it does not always build against the
# Asahi kernel), plus disko and nixos-facter for installing cale onto LUKS +
# ZFS. Built on the same nixpkgs as cale, so the installer's ZFS matches the
# one cale boots with.
#
# .github/workflows/asahi-installer.yml builds it; the ISO is that run's
# artifact. By hand, on an aarch64-linux machine:
#   nix build .#packages.aarch64-linux.asahi-installer
{ inputs, ... }:
let
  system = "aarch64-linux";

  installer = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      inputs.nixos-apple-silicon.nixosModules.apple-silicon-installer
      (
        { lib, pkgs, ... }:
        {
          nixpkgs.hostPlatform = system;

          # The upstream installer sets this to false; force it back on.
          boot.supportedFilesystems.zfs = lib.mkForce true;
          # ZFS wants a host ID; any fixed one does for a live system.
          networking.hostId = "5a5a5a5a";

          environment.systemPackages = [
            pkgs.git
            pkgs.nixos-facter
            pkgs.ssh-to-age
            inputs.disko.packages.${system}.disko
          ];

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
        }
      )
    ];
  };
in
{
  flake.packages.${system}.asahi-installer = installer.config.system.build.isoImage;
}
