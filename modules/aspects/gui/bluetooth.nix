# Bluetooth, on from boot, and headphones kept sounding like headphones.
{ ... }:
{
  den.aspects.gui.nixos = {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };

    # WirePlumber exposes the AirPods as a virtual mic and, the moment
    # anything opens it, flips the card from A2DP to HSP/HFP -- choppy,
    # phone-quality audio and an extra RFCOMM link that keeps dropping.
    # Stay on A2DP; switch to the headset profile by hand for calls.
    services.pipewire.wireplumber.extraConfig."52-bluetooth-no-autoswitch" = {
      "wireplumber.settings"."bluetooth.autoswitch-to-headset-profile" = false;
    };
  };
}
