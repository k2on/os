# An Apple silicon Mac running Asahi Linux (nixos-apple-silicon). Each file
# here adds its part to den.aspects.asahi; those in ./gui add theirs to
# den.aspects.asahi.provides.gui, which only a host with the gui aspect
# (aspects/gui) gets: the GPU, the speakers and the microphone. A server Mac
# has neither, and so no PipeWire, which nixos-apple-silicon would otherwise
# set up for any Mac.
#
# Each Mac has firmware of its own (its Wi-Fi and Bluetooth, from its
# macOS), so a host includes this with it, as `asahi._.firmware ./firmware`.
{
  den,
  inputs,
  lib,
  ...
}:
{
  den.aspects.asahi = {
    # This aspect, for the Mac whose firmware (the firmware.cpio the Asahi
    # installer makes) is in `dir`.
    provides.firmware = dir: {
      includes = [ den.aspects.asahi ];
      nixos.hardware.asahi.peripheralFirmwareDirectory = dir;
    };

    nixos = {
      imports = [ inputs.nixos-apple-silicon.nixosModules.apple-silicon-support ];

      hardware.asahi = {
        enable = true;
        setupAsahiSound = lib.mkDefault false;
      };
    };

    includes = [
      (den.lib.policy.when ({ host, ... }: host.hasAspect den.aspects.gui) den.aspects.asahi.provides.gui)
    ];
  };
}
