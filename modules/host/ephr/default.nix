# ephr: the backup server, a MacBook Air (M1, 2020) on Asahi at home,
# which ark's restic jobs send their remote copies to.
#
# On the same nixpkgs and nixos-apple-silicon as cale. Its firmware
# (./firmware) is the firmware.cpio the Asahi installer makes, here built
# with asahi-fwextract from the all_firmware.tar.gz and kernelcache its
# installer left on the ESP in /boot/asahi.
{ inputs, den, ... }:
let
  # This folder's name: the host's, its flake output's and its hostname.
  name = baseNameOf ./.;
in
{
  den.hosts.aarch64-linux.${name} = {
    instantiate = inputs.nixpkgs.lib.nixosSystem;
  };

  den.aspects.${name} = {
    includes = [ den.aspects.deploy ];

    nixos = {
      imports = [
        inputs.nixos-apple-silicon.nixosModules.apple-silicon-support
        ./_hardware-configuration.nix
        ./_configuration.nix
      ];

      hardware.asahi = {
        enable = true;
        peripheralFirmwareDirectory = ./firmware;
      };
    };
  };
}
