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
    color = "#40a02b"; # dark green
    # Nobody can get to its console: root over ssh, with a YubiKey key
    # (modules/keys/max.pub), is the way back in if Kanidm logins fail.
    console = false;
    rootSsh = true;
  };

  den.aspects.${name} = {
    includes = with den.aspects; [
      (asahi._.firmware ./firmware)
    ];

    nixos = {
      imports = [
        ./_hardware-configuration.nix
        ./_configuration.nix
      ];

      # Its age recipient (ssh-to-age of the host's ed25519 key,
      # modules/keys/hosts/ephr.pub), for the secrets its aspects declare
      # (lib/secrets.nix).
      ark.hostKey = "age15j46nxjhx4zy82c7prafy7uhg6kgca8kzklxd2w0ppcmg6r0xqvqldm402";
    };
  };
}
