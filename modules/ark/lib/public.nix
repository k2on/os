# Names reachable from the internet, not just the tailnet.
#
# Every service on ark is private: its name resolves to ark's tailnet
# address (headscale's extra_records) and nothing else answers for it. A
# few things have to be public — the identity provider, photo shares —
# and for those the vps is the front door: it holds the public DNS
# record and passes TLS straight through to ark, routed on the SNI name,
# without terminating it (ark has the wildcard cert; the vps never sees
# the traffic). Register such a label with the port on ark it lands on:
#
#   ark.public.id = 8443;      # id.<mainDomain>    -> ark:8443 (kanidm itself)
#   ark.public.share = 443;    # share.<mainDomain> -> ark:443  (its nginx)
#
# The host running headscale consumes this (services/headscale): one DNS
# record and one stream-map entry per label.
{ lib, config, ... }:
{
  options.ark.public = lib.mkOption {
    type = lib.types.attrsOf lib.types.port;
    default = { };
    description = "Public labels under mainDomain -> port on ark the vps passes their TLS through to.";
  };

  options.ark.publicDomains = lib.mkOption {
    type = lib.types.attrsOf lib.types.port;
    readOnly = true;
    default = lib.mapAttrs' (
      name: port: lib.nameValuePair "${name}.${config.ark.mainDomain}" port
    ) config.ark.public;
    description = "ark.public keyed by full domain name.";
  };
}
