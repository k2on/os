# Every host is on the tailnet, joined as itself (den.aspects.tailnet,
# services/headscale: the shared pre-auth key, as the `ark` user). Except a
# desktop: there the node belongs to whoever signs in (aspects/gui/tailscale.nix).
{ den, ... }:
{
  den.schema.host.includes = [
    (den.lib.policy.when ({ host, ... }: !(host.hasAspect den.aspects.gui)) den.aspects.tailnet)
  ];
}
