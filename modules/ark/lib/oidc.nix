# OIDC clients for ark services, provisioned in kanidm (host/adam/kanidm.nix).
#
# A service opts in by declaring `oidc` on its ark.services spec (see
# lib/services.nix). Who may use it is not part of the spec: persons and
# per-service group memberships live in the secrets repo (secrets/ark.nix),
# and every group listed there becomes the kanidm group <service>_<group>.
# `service.oidc.groups.<group>.claim` is the value clients see in the
# `groups` claim, for modules that map roles or restrict logins.
#
# The client's icon is modules/ark/services/<service>/icon.svg when present.
{ lib, config, ... }:
let
  mainDomain = config.ark.mainDomain;

  clientFor =
    name: spec:
    let
      o = spec.oidc;
      domain = config.ark.serviceDomain name spec;
      issuer = "https://id.${mainDomain}/oauth2/openid/${name}";
      icon = ../services/${name}/icon.svg;
    in
    {
      inherit domain issuer;
      inherit (config.ark.oidc) name;
      clientId = name;
      discovery = "${issuer}/.well-known/openid-configuration";
      secret = "${name}_oidc_client_secret";
      icon = if builtins.pathExists icon then icon else null;
      displayName = o.displayName or (lib.toSentenceCase name);
      landing = o.landing or "https://${domain}";
      callbacks = map (c: if lib.hasPrefix "/" c then "https://${domain}${c}" else c) o.callbacks;
      scopes =
        o.scopes or [
          "openid"
          "profile"
          "email"
          "groups"
        ];
      pkce = o.pkce or true;
      groups = lib.mapAttrs (g: members: {
        inherit members;
        name = "${name}_${g}";
        claim = "${name}_${g}@id.${mainDomain}";
      }) (config.ark.groups.${name} or { });
    };
in
{
  options.ark = {
    persons = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options.displayName = lib.mkOption { type = lib.types.str; };
            options.mail = lib.mkOption {
              type = lib.types.str;
              default = "${name}@${mainDomain}";
            };
          }
        )
      );
      default = { };
      description = "Everyone with a kanidm account, keyed by username.";
    };
    groups = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.str));
      default = { };
      description = "<service> -> <group> -> persons. Each entry is the kanidm group <service>_<group>.";
    };
    oidc.name = lib.mkOption {
      type = lib.types.str;
      description = "What clients call the identity provider (login buttons, gitea's auth source, ...).";
    };
    oidc.clients = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = lib.mapAttrs clientFor (
        lib.filterAttrs (_: s: lib.isAttrs s && (s.oidc or null) != null) config.ark.services
      );
      description = "Resolved client info for every service declaring `oidc`, keyed by service name.";
    };
  };
}
