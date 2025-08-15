{ inputs, ... }: {
  time.timeZone = "America/New_York";

  services.tailscale.enable = true;

  # security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
