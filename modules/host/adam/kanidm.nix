{ config, lib, ... }:
let
  ark = config.ark;
  clients = ark.oidc.clients;
in
{
  # kanidm terminates its own TLS; the vps passes id.* through to it (lib/public.nix).
  ark.public.id = 8443;

  flake.nixosModules.kanidm =
    { pkgs, config, ... }:
    {
      # kanidm's own copy of every service's client secret. The service's
      # copy is declared by ark.services (lib/services.nix) on whichever
      # host runs it; both read the same secrets/vars file.
      # idm_admin's password, so steps after provisioning can sign in as it
      # (services/sivrad/_kanidm.nix sets the sivrad account's password); the
      # module recovers the account with it on every start.
      # admin's too, which alone may change the domain's own settings
      # (kanidm-domain below).
      ark.secrets = {
        kanidm_idm_admin_password = {
          generate = true;
          owner = "kanidm";
        };
        kanidm_admin_password = {
          generate = true;
          owner = "kanidm";
        };
      }
      // lib.mapAttrs' (
        _: o:
        lib.nameValuePair "${o.secret}_kanidm" {
          key = o.secret;
          owner = "kanidm";
        }
      ) (lib.filterAttrs (_: o: !o.public) clients);

      # 1.10 is end-of-life upstream and marked insecure in nixpkgs. Bumping to
      # 1.11 migrates the server database: run `kanidmd domain upgrade-check`
      # on adam first, then change the package and drop this allowance.
      nixpkgs.config.permittedInsecurePackages = [
        "kanidm-with-secret-provisioning-1.10.5"
      ];

      # Kanidm keeps no pictures, and a claim map cannot hold a URL (its
      # values allow no `/` or `.`), so ./kanidm-picture.patch makes the
      # `picture` claim from KANIDM_OAUTH2_PICTURE_URL, which is
      # ark.oidc.picture (lib/oidc.nix). It means Kanidm is built from
      # source here, and the patch is carried to 1.11.
      services.kanidm = {
        package = pkgs.kanidmWithSecretProvisioning_1_10.overrideAttrs (o: {
          patches = (o.patches or [ ]) ++ lib.optional (ark.oidc.picture != null) ./kanidm-picture.patch;
          # Upstream's release profile (thin LTO, one codegen unit, debug info)
          # wants more memory for kanidmd_lib than adam has beside its
          # services: earlyoom killed rustc at 3.2 GB. Still opt-level 3. In
          # env: the derivation has structured attrs, which export only that.
          env = o.env // {
            CARGO_PROFILE_RELEASE_LTO = "off";
            CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
            CARGO_PROFILE_RELEASE_DEBUG = "0";
          };
        });
        server = {
          enable = true;
          settings = {
            domain = "id.${ark.mainDomain}";
            origin = "https://id.${ark.mainDomain}";
            bindaddress = "0.0.0.0:8443";

            tls_chain = "/var/lib/acme/${ark.mainDomain}/fullchain.pem";
            tls_key = "/var/lib/acme/${ark.mainDomain}/key.pem";

          };
        };

        client = {
          enable = true;
          settings.uri = "https://id.${ark.mainDomain}";
        };

        # Persons and group memberships come from the secrets repo
        # (secrets/ark.nix); clients from each service's `oidc` (lib/oidc.nix).
        provision = {
          enable = true;
          idmAdminPasswordFile = config.sops.secrets.kanidm_idm_admin_password.path;
          adminPasswordFile = config.sops.secrets.kanidm_admin_password.path;

          persons = lib.mapAttrs (_: p: {
            inherit (p) displayName;
            mailAddresses = [ p.mail ];
          }) ark.persons;

          groups = lib.concatMapAttrs (
            _: o: lib.mapAttrs' (_: g: lib.nameValuePair g.name { inherit (g) members; }) o.groups
          ) clients;

          # Keyed by the client id, which is the service name unless the
          # service says otherwise (lib/oidc.nix).
          systems.oauth2 = lib.mapAttrs' (
            _: o:
            lib.nameValuePair o.clientId (
              {
                inherit (o) displayName public;
                originUrl = o.callbacks;
                originLanding = o.landing;
                preferShortUsername = true;
                scopeMaps = lib.mapAttrs' (_: g: lib.nameValuePair g.name o.scopes) o.groups;
                allowInsecureClientDisablePkce = !o.pkce;
                enableLegacyCrypto = o.legacyCrypto;
              }
              // lib.optionalAttrs (!o.public) {
                basicSecretFile = config.sops.secrets."${o.secret}_kanidm".path;
              }
              // lib.optionalAttrs (o.icon != null) { imageFile = o.icon; }
            )
          ) clients;
        };
      };

      networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8443 ];

      # Off the tailnet, id.* and the public names nginx serves (harken.*,
      # share.*) are all the vps's address under the one *.<mainDomain>
      # certificate, so a browser reuses its HTTP/2 connection to nginx for
      # id.* — and nginx, which has no id.*, answered 404. 421 tells the
      # browser it is the wrong connection, and it opens one of its own,
      # which the vps routes to Kanidm.
      services.nginx.virtualHosts."id.${ark.mainDomain}" = {
        useACMEHost = ark.mainDomain;
        onlySSL = true;
        locations."/".return = "421";
      };

      systemd.services.kanidm = {
        wants = [ "acme-finished-${ark.mainDomain}.target" ];
        after = [ "acme-finished-${ark.mainDomain}.target" ];
      };

      systemd.services.kanidm.serviceConfig.ExecReload = "/run/current-system/sw/bin/kill -HUP $MAINPID";
      systemd.services.kanidm.environment = lib.optionalAttrs (ark.oidc.picture != null) {
        KANIDM_OAUTH2_PICTURE_URL = ark.oidc.picture;
      };

      # The tab and home screen icons are ark.oidc.logo too. Kanidm's pages
      # show the domain image (kanidm-domain below), but their icons are
      # files of its package (/pkg/img), so its own are covered, inside its
      # mount namespace, by ones made from the logo at their sizes: no
      # rebuild of Kanidm. logo-square.svg (the manifest's and the largest
      # touch icon) is an SVG of the PNG.
      systemd.services.kanidm.serviceConfig.BindReadOnlyPaths = lib.mkIf (ark.oidc.logo != null) (
        let
          icons = pkgs.runCommand "kanidm-icons" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
            mkdir $out
            png() { magick ${ark.oidc.logo} -background none -resize "$1x$1" -gravity center -extent "$1x$1" -strip "png:$out/$2"; }
            png 32 favicon.png
            png 256 apple-touch-icon.png
            for s in 180 192 256 512; do png $s logo-$s.png; done
            printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><image width="512" height="512" href="data:image/png;base64,%s"/></svg>' \
              "$(base64 -w0 $out/logo-512.png)" > $out/logo-square.svg
          '';
          img = "${config.services.kanidm.package}/ui/hpkg/img";
        in
        map (f: "${icons}/${f}:${img}/${f}") [
          "favicon.png"
          "apple-touch-icon.png"
          "logo-180.png"
          "logo-192.png"
          "logo-256.png"
          "logo-512.png"
          "logo-square.svg"
        ]
      );

      # Kanidm's own pages are titled ark.oidc.name and show ark.oidc.logo
      # (lib/oidc.nix), which kanidm-provision does not do: the domain's
      # display name and image may be changed only by admin, through the
      # API, as `kanidm system domain set-displayname` and `set-image` do.
      # Signed in as admin (its password kept above), each is set when it
      # differs; it runs on every boot and whenever either changes here.
      systemd.services.kanidm-domain =
        let
          url = "https://id.${ark.mainDomain}";
          logo = ark.oidc.logo;
          types = {
            png = "image/png";
            jpg = "image/jpeg";
            jpeg = "image/jpeg";
            gif = "image/gif";
            webp = "image/webp";
            svg = "image/svg+xml";
          };
          ext = lib.toLower (lib.last (lib.splitString "." (baseNameOf logo)));
        in
        {
          description = "Kanidm's name and logo";
          wantedBy = [ "multi-user.target" ];
          requires = [ "kanidm.service" ];
          after = [ "kanidm.service" ];
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.gawk
            pkgs.jq
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -euo pipefail
            url=${url}
            json() { curl -sS --fail-with-body -H 'Content-Type: application/json' "$@"; }

            # A read-write session as admin: /v1/auth, its id in a header.
            s=$(curl -sS -D - -o /dev/null -H 'Content-Type: application/json' \
              -d '{"step":{"init2":{"username":"admin","issue":"token","privileged":true}}}' \
              "$url/v1/auth" | tr -d '\r' | awk 'tolower($1) == "x-kanidm-auth-session-id:" { print $2 }')
            step() { json -H "X-KANIDM-AUTH-SESSION-ID: $s" -d "$1" "$url/v1/auth"; }
            step '{"step":{"begin":"password"}}' >/dev/null
            token=$(step "$(jq -cn --arg p "$(< ${config.sops.secrets.kanidm_admin_password.path})" '{step: {cred: {password: $p}}}')" | jq -er '.state.success')
            auth=(-H "Authorization: Bearer $token")

            name=${lib.escapeShellArg ark.oidc.name}
            attr=$url/v1/domain/_attr/domain_display_name
            if [ "$(json "''${auth[@]}" "$attr" | jq -r '.[0] // ""')" != "$name" ]; then
              json "''${auth[@]}" -X PUT -d "$(jq -cn --arg n "$name" '[$n]')" "$attr" >/dev/null
              echo "named $name"
            fi

            # The image as Kanidm serves it on its pages, to compare.
            current=$(mktemp)
            trap 'rm -f "$current"' EXIT
            have=$(curl -sS -o "$current" -w '%{http_code}' "$url/ui/images/domain")
            ${
              if logo == null then
                ''
                  if [ "$have" = 200 ]; then
                    json "''${auth[@]}" -X DELETE "$url/v1/domain/_image" >/dev/null
                    echo "logo removed"
                  fi
                ''
              else
                ''
                  if [ "$have" != 200 ] || ! cmp -s "$current" ${logo}; then
                    curl -sS --fail-with-body "''${auth[@]}" \
                      -F "image=@${logo};type=${types.${ext}};filename=logo.${ext}" \
                      "$url/v1/domain/_image" >/dev/null
                    echo "logo set"
                  fi
                ''
            }
          '';
        };
    };
}
