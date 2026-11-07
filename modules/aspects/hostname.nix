{ den, ... }:
{
  # Every host goes by its den name: the flake output, networking.hostName,
  # and so its tailnet name and comin's default.
  den.default.includes = [ den.batteries.hostname ];
}
