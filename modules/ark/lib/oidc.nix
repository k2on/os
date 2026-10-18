# OIDC clients for ark services, provisioned in kanidm (host/adam/kanidm.nix).
#
# A service opts in by declaring `oidc` on its ark.services spec (see
# lib/services.nix). Who may use it is not part of the spec: persons, groups
# of them and who gets which role in which service (ark.access) live in the
# secrets repo (secrets/ark.nix), and every role listed in ark.access becomes
# the kanidm group <service>_<role>.
# `service.oidc.groups.<group>.claim` is the value clients see in the
# `groups` claim, for modules that map roles or restrict logins. A service
# may add groups of its own with `oidc.groups.<group> = [ persons ]` (for
# memberships it derives rather than reads from the secrets repo).
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
      # Kanidm names are unique across clients, groups and persons, so a
      # service may call its client something else.
      clientId = o.clientId or name;
      issuer = "https://id.${mainDomain}/oauth2/openid/${clientId}";
      icon = ../services/${name}/icon.svg;
    in
    {
      inherit domain issuer clientId;
      inherit (config.ark.oidc) name;
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
      # A public client (a phone app, say): PKCE, no client secret.
      public = o.public or false;
      pkce = o.pkce or true;
      # kanidm signs tokens with ES256; clients that only verify RS256 need this.
      legacyCrypto = o.legacyCrypto or false;
      groups = lib.mapAttrs (g: members: {
        inherit members;
        name = "${name}_${g}";
        claim = "${name}_${g}@id.${mainDomain}";
      }) ((config.ark.access.${name} or { }) // (o.groups or { }));
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
            options.signal = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "+15551234567";
              description = "Signal number in E.164, or Signal username (name.NN) for someone who does not share their number. A person with one may use sivrad (the phone app and Signal).";
            };
          }
        )
      );
      default = { };
      description = "Everyone with a kanidm account, keyed by username.";
    };
    groups = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf (lib.types.enum (lib.attrNames config.ark.persons)));
      default = { };
      example = {
        family = [ "<person>" ];
        admin = [ "<person>" ];
      };
      description = "Groups of persons, by name. ark.access grants them services; services may use them directly too (each has a shared mailbox and vault).";
    };
    access = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.str));
      default = { };
      example = {
        git = {
          members = [ "<person>" ];
          admin = [ "<person>" ];
        };
      };
      description = "<service> -> <role> -> persons. Each entry is the kanidm group <service>_<role>.";
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
