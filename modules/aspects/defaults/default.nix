# What every host gets, without listing it (den.schema.host.includes): each
# file here adds its part. A host's own default.nix lists only what is its
# alone.
#
#   deploy.nix    comin: each host deploys itself from main
#   gc.nix        weekly clean-up of the store, 5 generations kept
#   metrics.nix   node_exporter, comin's metrics and the journal, to dash
#   security.nix  certificate authorities no host should trust
#   shell.nix     zsh with vi keys, the prompt in the host's colour
#
# And, here: the host's name, and whether its accounts are mutable.
{ den, lib, ... }:
{
  den.schema.host.includes = [
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
