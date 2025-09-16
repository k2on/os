{ inputs, ... }: {
  time.timeZone = "America/New_York";

  # security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
