# Service registry with automatic port assignment, built on Den quirks.
#
# Define a service ONCE under koon.services, in one of two forms:
#
#   # bare function — auto-assigned port, default domain
#   koon.services.git = { service, config, pkgs, ... }: {
#     services.gitea.settings.server.HTTP_PORT = service.port;
#   };
#
#   # attrset — when pinning a port or domain
#   koon.services.home = {
#     port = 8123;                 # optional: omit to auto-assign
#     domain = "home.koon.us";     # optional: defaults to "<name>.koon.us"
#     make = { service, pkgs, ... }: { ... };   # or a plain module attrset
#   };
#
# The module function receives ordinary NixOS module args (config, pkgs,
# lib, ...) PLUS `service` = { name, port, domain }, pre-applied the same
# way Den's wrapClassModule injects host/user — pipeline data resolved
# before module evaluation, so ports can never cause infinite recursion.
#
# Each entry generates den.aspects.service-<name>; hosts opt in:
#   den.aspects.ark.includes = with den.aspects; [ service-git ... ];
#
# Auto-assigned ports are portBase + index in the alphabetically sorted
# list of auto-assigned services on that host. Quirk data is scope-local,
# so each host's ports come from only the services it includes.
{ lib, config, ... }:
let
  portBase = 31600;

  # Accept both definition forms; always work with { port?, domain?, make }.
  normalize = spec:
    if lib.isFunction spec then { make = spec; } else spec;

  # list of { <name> = spec; } (one per producing aspect) -> { name -> spec }
  # Fails loudly if two producers register the same service name.
  mergeServices = regs:
    lib.foldl'
      (acc: reg:
        let dup = lib.intersectLists (lib.attrNames acc) (lib.attrNames reg);
        in if dup != [ ]
           then throw "ark: duplicate service registration(s): ${toString dup}"
           else acc // lib.mapAttrs (_: normalize) reg)
      { }
      regs;

  # { name -> spec } -> { name -> port }
  assignPorts = services:
    let
      autoNames = lib.sort lib.lessThan
        (lib.attrNames (lib.filterAttrs (_: s: (s.port or null) == null) services));
      autoFor = name:
        portBase + (10 * lib.lists.findFirstIndex (n: n == name)
          (throw "ark: unregistered service '${name}'")
          autoNames);
    in
    lib.mapAttrs
      (name: s: if (s.port or null) != null then s.port else autoFor name)
      services;

  domainFor = name: spec: spec.domain or "${name}.koon.us";

  # Turn a spec into a NixOS module, injecting `service` alongside the
  # normal module args. setFunctionArgs advertises the user function's
  # own argument names (minus service) so the module system supplies
  # config/pkgs/lib/etc. as usual.
  mkModule = name: port: spec:
    let
      service = { inherit name port; domain = domainFor name spec; };
      m = spec.make or { };
    in
    if lib.isFunction m then
      lib.setFunctionArgs
        (args: m (args // { inherit service; }))
        (builtins.removeAttrs (lib.functionArgs m) [ "service" ])
    else
      m;
in
{
  options.ark = {
    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      description = ''
        Service definitions. Either a module function taking
        { service, config, pkgs, lib, ... }, or an attrset
        { port ? auto, domain ? "<name>.koon.us", make ? <module> }.
        Each entry generates den.aspects.service-<name>.
      '';
    };
    mergeServices = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = mergeServices;
    };
    assignServicePorts = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = assignPorts;
      description = "Compute { name -> port } from merged ark-service registrations.";
    };
    serviceDomain = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = domainFor;
    };
  };

  config.den = {
    quirks.ark-service.description =
      "Service registrations keyed by name: { <name> = <module fn> | { port ?, domain ?, make ? }; }";

    aspects =
      # One generated aspect per defined service; including it on a host
      # is what registers (and therefore runs) the service there.
      lib.mapAttrs'
        (name: spec:
          lib.nameValuePair "service-${name}" {
            ark-service.${name} = spec;
          })
        config.ark.services
      // {
        # Consumer: instantiates every registered service on this host
        # with its resolved port.
        ark-services.nixos = { ark-service, ... }:
          let
            services = mergeServices ark-service;
            ports = assignPorts services;
          in
          {
            imports = lib.mapAttrsToList
              (name: spec: mkModule name ports.${name} spec)
              services;
          };
      };

    # Active on every host; inert (empty) where nothing registers.
    schema.host.includes = [ config.den.aspects.ark-services ];
  };
}
