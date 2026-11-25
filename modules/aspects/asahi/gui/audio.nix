# The speakers and microphone: Asahi's DSP setup, on a PipeWire with its fix.
{ self, ... }:
{
  den.aspects.asahi.provides.gui.nixos =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.commonUnstablePkgsOverlay ];

      hardware.asahi.setupAsahiSound = true;

      # PipeWire < 1.4.10 has a bug where the Asahi DSP speaker sink comes up
      # with its volume locked at 100% after boot and can't be changed until
      # some audio has played once (upstream
      # https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/4900,
      # AsahiLinux/asahi-audio#73). nixos-25.11 ships 1.4.9, so pull PipeWire
      # and its matching WirePlumber from unstable where the fix is present.
      services.pipewire.package = pkgs.pkgs-unstable.pipewire;
      services.pipewire.wireplumber.package = pkgs.pkgs-unstable.wireplumber;

      # The internal microphone hangs off a second ALSA card (the AOP
      # "High-Power Audio Interface", alsa_card.platform-audio.*). asahi-audio
      # only spawns the j414-mic DSP chain -- and with it the only usable
      # internal mic source -- while that card sits in its HiFi profile.
      # WirePlumber restores whichever profile it last saved in
      # ~/.local/state/wireplumber/default-profile, so a single stray "off"
      # there silently kills the mic on every subsequent boot. Refuse to
      # restore an "off" profile for this one card; WirePlumber then falls back
      # to picking HiFi itself. Bluetooth profile restore is unaffected.
      services.pipewire.wireplumber.extraConfig."51-asahi-internal-mic" = {
        "monitor.alsa.rules" = [
          {
            matches = [ { "device.name" = "~alsa_card.platform-audio.*"; } ];
            actions.update-props."session.dont-restore-off-profile" = true;
          }
        ];
      };
    };
}
