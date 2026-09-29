# Service registry with automatic port assignment, built on Den quirks.
#
# Each service lives in modules/ark/services/<name>/default.nix, with an
# optional icon.svg next to it. Define it ONCE under ark.services, in one
# of two forms:
#
#   # bare function — auto-assigned port, default domain, no OIDC
#   ark.services.git = { service, config, pkgs, ... }: {
#     services.gitea.settings.server.HTTP_PORT = service.port;
#   };
#
#   # attrset — everything optional except nixos
#   ark.services.home = {
#     port = 8123;                 # omit to auto-assign
#     domain = "home.ark.us";     # defaults to "<name>.<ark.mainDomain>"
#     aliases = [ "office" ];     # other names that reach this service; bare labels get mainDomain
#     oidc = {                    # declaring this gives the service a kanidm client
#       callbacks = [ "/auth/oidc/callback" ];    # relative to https://<domain>, or absolute
#       displayName = "Home";     # defaults to the capitalised name
#       landing = "https://...";  # defaults to https://<domain>
#       scopes = [ ... ];         # defaults to openid profile email groups
#       pkce = true;              # false for clients that cannot do PKCE
#       legacyCrypto = false;     # true for clients that only accept RS256 tokens
#       owner = "hass";           # unix user on this host that reads the secret file
#     };
#     secrets.home_token = { };   # other sops secrets, see lib/secrets.nix
#     nixos = { service, pkgs, ... }: { ... };   # or a plain module attrset
#   };
#
# The module function receives ordinary NixOS module args (config, pkgs,
# lib, ...) PLUS `service` = { name, port, domain, oidc? }, pre-applied the
# same way Den's wrapClassModule injects host/user — pipeline data resolved
# before module evaluation, so ports can never cause infinite recursion.
# With OIDC, service.oidc is the client from lib/oidc.nix (name, clientId,
# issuer, discovery, groups.<g>.claim, ...) plus the secret as
# clientSecretFile (a path) and clientSecret (a sops placeholder).
#
# Each entry generates den.aspects.service-<name>; hosts opt in:
#   den.aspects.ark.includes = with den.aspects; [ service-git ... ];
#
# The OIDC client secret is one secrets/vars file, declared here for the
# host running the service and again by kanidm for its own host, so the
# two may be different machines.
#
# Auto-assigned ports are portBase + index in the alphabetically sorted
# list of auto-assigned services on that host. Quirk data is scope-local,
# so each host's ports come from only the services it includes.
{ lib, config, ... }:
let
  portBase = 31600;

  # Accept both definition forms; always work with { port?, domain?, oidc?, nixos }.
  normalize = spec: if lib.isFunction spec then { nixos = spec; } else spec;

  # list of { <name> = spec; } (one per producing aspect) -> { name -> spec }
  # Fails loudly if two producers register the same service name.
  mergeServices =
    regs:
    lib.foldl' (
      acc: reg:
      let
        dup = lib.intersectLists (lib.attrNames acc) (lib.attrNames reg);
      in
      if dup != [ ] then
        throw "ark: duplicate service registration(s): ${toString dup}"
      else
        acc // lib.mapAttrs (_: normalize) reg
    ) { } regs;

  # { name -> spec } -> { name -> port }
  assignPorts =
    services:
    let
      autoNames = lib.sort lib.lessThan (
        lib.attrNames (lib.filterAttrs (_: s: (s.port or null) == null) services)
      );
      autoFor =
        name:
        portBase
        + (
          10 * lib.lists.findFirstIndex (n: n == name) (throw "ark: unregistered service '${name}'") autoNames
        );
    in
    lib.mapAttrs (name: s: if (s.port or null) != null then s.port else autoFor name) services;

  domainFor = name: spec: spec.domain or "${name}.${config.ark.mainDomain}";

  # Every name a service answers to: its domain plus aliases.
  domainsFor =
    name: spec:
    [ (domainFor name spec) ]
    ++ map (a: if lib.hasInfix "." a then a else "${a}.${config.ark.mainDomain}") (spec.aliases or [ ]);

  # Turn a spec into a NixOS module, injecting `service` alongside the
  # normal module args. setFunctionArgs advertises the user function's
  # own argument names (minus service, plus config for the secret paths)
  # so the module system supplies config/pkgs/lib/etc. as usual.
  mkModule =
    name: port: spec:
    let
      oidc = config.ark.oidc.clients.${name} or null;
      service =
        args:
        {
          inherit name port;
          domain = domainFor name spec;
        }
        // lib.optionalAttrs (oidc != null) {
          oidc = oidc // {
            clientSecretFile = args.config.sops.secrets.${oidc.secret}.path;
            clientSecret = args.config.sops.placeholder.${oidc.secret};
          };
        };
      m = spec.nixos or { };
    in
    if lib.isFunction m then
      lib.setFunctionArgs (args: m (args // { service = service args; })) (
        builtins.removeAttrs (lib.functionArgs m) [ "service" ] // { config = false; }
      )
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
        { port ?, domain ?, oidc ?, secrets ?, nixos }.
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
    serviceDomains = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = lib.mapAttrs (name: spec: domainsFor name (normalize spec)) config.ark.services;
      description = "{ name -> [ domain aliases... ] } for every registered service.";
    };
  };

  config.den = {
    quirks.ark-service.description = "Service registrations keyed by name: { <name> = <module fn> | { port ?, domain ?, oidc ?, secrets ?, nixos ? }; }";

    aspects =
      # One generated aspect per defined service; including it on a host
      # is what registers (and therefore runs) the service there.
      lib.mapAttrs' (
        name: raw:
        let
          spec = normalize raw;
          oidc = config.ark.oidc.clients.${name} or null;
        in
        lib.nameValuePair "service-${name}" (
          {
            ark-service.${name} = raw;
            secrets =
              (spec.secrets or { })
              // lib.optionalAttrs (oidc != null) {
                ${oidc.secret} = {
                  generate = true;
                }
                // lib.optionalAttrs (spec.oidc ? owner) { inherit (spec.oidc) owner; };
              };
          }
          # Anything else on a spec is quirk data (dns_records, ...) and goes
          # on the aspect as-is. Not checked against den.quirks: reading it
          # while defining den.aspects is an infinite recursion.
          // builtins.removeAttrs spec [
            "port"
            "domain"
            "aliases"
            "oidc"
            "secrets"
            "nixos"
          ]
        )
      ) config.ark.services
      // {
        # Consumer: instantiates every registered service on this host
        # with its resolved port, and records which they are.
        ark-services.nixos =
          { ark-service, ... }:
          let
            services = mergeServices ark-service;
            ports = assignPorts services;
          in
          {
            imports = lib.mapAttrsToList (name: spec: mkModule name ports.${name} spec) services;
            options.ark.hostedServices = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              readOnly = true;
              default = lib.attrNames services;
              description = "The ark services this host runs (from the service-<name> aspects it includes).";
            };
          };
      };

    # Active on every host; inert (empty) where nothing registers.
    schema.host.includes = [ config.den.aspects.ark-services ];
  };

  # Consumed by the `ark` CLI (`ark hosts`, and service commands that reach
  # their host): every host, how to ssh to it, and the services it runs.
  #   { adam = { name = "adam"; hostName = "ark"; ssh = "admin@ark.net.example.com"; services = [ "money" ... ]; }; ... }
  # The ssh target is all derived: the host's one sudo user, at its MagicDNS
  # name on the tailnet (headscale's base_domain, read off the host running
  # headscale). null where that does not add up (no tailscale, no or several
  # sudo users, no headscale anywhere).
  config.flake.arkHosts =
    let
      hosts = lib.filterAttrs (_: h: h.config ? ark) config.flake.nixosConfigurations;
      runsHeadscale = lib.filterAttrs (
        _: h: lib.elem "headscale" (h.config.ark.hostedServices or [ ])
      ) hosts;
      tailnetDomain = lib.mapAttrsToList (
        _: h: h.config.services.headscale.settings.dns.base_domain or null
      ) runsHeadscale;
      sshTarget =
        host:
        let
          users = lib.attrNames (
            lib.filterAttrs (_: u: u.isNormalUser && lib.elem "wheel" u.extraGroups) host.config.users.users
          );
          onTailnet = host.config.services.tailscale.enable or false;
        in
        if onTailnet && lib.length users == 1 && tailnetDomain != [ ] && lib.head tailnetDomain != null then
          "${lib.head users}@${host.config.networking.hostName}.${lib.head tailnetDomain}"
        else
          null;
    in
    lib.mapAttrs (name: host: {
      inherit name;
      hostName = host.config.networking.hostName;
      ssh = sshTarget host;
      services = host.config.ark.hostedServices or [ ];
    }) hosts;
}
