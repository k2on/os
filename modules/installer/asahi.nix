# A generic installer ISO for any Apple Silicon Mac: nixos-apple-silicon's
# installer with ZFS turned back on (it leaves ZFS out, since it does not
# always build against the Asahi kernel), plus disko and nixos-facter. It
# holds nothing host-specific: boot it, then install a host's own profile
# from this flake, e.g.
#   disko --mode format,mount --flake '.?submodules=1#cale'
#   nixos-install --flake '.?submodules=1#cale'
# Built on this flake's nixpkgs, so its ZFS matches the hosts it installs.
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
