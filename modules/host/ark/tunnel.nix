# The cloudflared tunnel, with ingress derived from koon-service
# registrations. Adding a service to ark's includes automatically adds
# its ingress entry.
{ config, ... }:
let
  # capture flake-level helpers before the inner NixOS `config` shadows this
  inherit (config.ark) mergeServices assignServicePorts serviceDomain;
in
{
  den.aspects.ark-tunnel.nixos = { ark-service, config, lib, ... }:
    let
      services = mergeServices ark-service;
      ports = assignServicePorts services;
      serviceIngress = lib.mapAttrs'
        (name: spec: lib.nameValuePair
          (serviceDomain name spec)
          "http://localhost:${toString ports.${name}}")
        services;
    in
    {
      services.cloudflared = {
        enable = true;
        tunnels."91d31395-fbc7-45a1-ae13-148957b32ecd" = {
          credentialsFile = config.sops.secrets.tunnel-credentials.path;
          default = "http_status:404";
          ingress = serviceIngress // {
            # not (yet) registered as ark-services — kept verbatim:
            "ssh.koon.us" = "ssh://localhost:2222";
            "media.koon.us" = "http://localhost:8096"; # Jellyfin does not let you configure this
          };
        };
      };
    };
}

