{ den, lib, ... }:
{
  den.default.includes = [
    # Every host goes by its den name: the flake output, networking.hostName,
    # and so its tailnet name and comin's default.
    den.batteries.hostname

    # Accounts are mutable unless the host says otherwise
    # (den.hosts.<…>.mutableUsers, lib/host-schema.nix).
    (
      { host, ... }:
      lib.optionalAttrs (host ? class && host.class == "nixos") {
        nixos.users.mutableUsers = host.mutableUsers;
      }
    )
  ];
}
