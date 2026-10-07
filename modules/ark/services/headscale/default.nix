# Headscale, and the tailnet every ark host joins.
#
# Joining is declarative on both ends, with no secret in the repo. A node's
# identity is its ed25519 ssh host key; its age recipient (ssh-to-age of the
# public key) is in the config as ark.hostKey, as sops already needs it.
# headscale's host (headscale-provision) mints one reusable pre-auth key per
# node, encrypts it to that recipient and serves the ciphertext at
# https://vpn.<domain>/tailnet/<node>.age. At boot a node fetches its file,
# decrypts it with its host key (tailnet-authkey) and hands the key to
# `tailscale up`. The ciphertexts are public: only the matching host key
# opens them, so joining as a node takes its ssh host key, as it did with
# sops. Revoking one is `headscale preauthkeys expire --id $(cat
# /var/lib/tailnet-keys/<node>.id)` on headscale's host, then a new
# recipient (or deleting <node>.age) to have a new one minted.
{ config, lib, ... }:
let
  ark = config.ark;
  tailnetUser = "ark";
  loginServer = "https://${ark.serviceDomain "headscale" ark.services.headscale}";
  # Where headscale-provision keeps what it minted: <node>.id and
  # <node>.recipient beside the served ciphertexts in pub/.
  keysDir = "/var/lib/tailnet-keys";
  keysPath = "/tailnet/";

  # Every node of the tailnet and its age recipient, read off every host:
  # itself and the VMs it runs (ark.tailnet.nodes), the way lib/secrets.nix
  # folds the hosts' secret declarations.
  tailnetNodes = lib.foldl' (acc: h: acc // (h.config.ark.tailnet.nodes or { })) { } (
    lib.attrValues (lib.filterAttrs (_: h: h.config ? ark) config.flake.nixosConfigurations)
  );

  # Public names the vps fronts for ark (lib/public.nix): TLS is passed
  # through untouched, routed on the SNI name to the given port on ark.
  # Everything else on 443 is the vps's own vhosts (headscale) on 8444.
  arkTailnetIp = "100.64.0.1";
  upstreamName = name: "ark_${lib.replaceStrings [ "." "-" ] [ "_" "_" ] name}";
  publicMap = lib.concatStrings (
    lib.mapAttrsToList (name: _: "  ${name}  ${upstreamName name};\n") ark.publicDomains
  );
  publicUpstreams = lib.concatStrings (
    lib.mapAttrsToList (name: port: ''
      upstream ${upstreamName name} {
        server ${arkTailnetIp}:${toString port};
      }
    '') ark.publicDomains
  );

  # A node of the tailnet, host or VM: fetches the pre-auth key headscale
  # minted for it and joins at boot. Also flake.nixosModules.ark-tailnet,
  # for nodes declared outside den (the sivrad microVM).
  tailnetModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.ark.tailnet;
      node = config.networking.hostName;
      hostKey = lib.findFirst (k: k.type == "ed25519") (throw
        "ark.tailnet: ${node} has no ed25519 key in services.openssh.hostKeys"
      ) config.services.openssh.hostKeys;
    in
    {
      options.ark.tailnet = {
        recipient = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            age recipient of this node's ed25519 ssh host key, the identity it
            joins the tailnet with: `ssh-to-age < ssh_host_ed25519_key.pub` on
            the machine. Hosts take it from ark.hostKey. null until read off a
            new machine after its first boot; headscale mints it no key until
            then, and it stays off the tailnet.
          '';
        };
        nodes = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = ''
            Node name -> age recipient of every tailnet node this host answers
            for: itself, and the VMs it runs. Folded over all hosts into
            headscale-provision on headscale's host.
          '';
        };
      };

      config = {
        assertions = [
          {
            assertion = config.services.openssh.enable;
            message = "ark.tailnet: ${node} needs services.openssh: its host key is the node's identity";
          }
        ];

        warnings = lib.optional (cfg.recipient == null) "ark.tailnet: ${node} has no recipient (ark.tailnet.recipient), so it does not join the tailnet";

        ark.tailnet.nodes = lib.mkIf (cfg.recipient != null) { ${node} = cfg.recipient; };

        services.tailscale = {
          enable = true;
          authKeyFile = lib.mkIf (cfg.recipient != null) "/run/tailnet/authkey";
          extraUpFlags = [
            "--login-server"
            loginServer
          ];
        };

        # The key headscale minted for this node, decrypted with the host key
        # (converted to the age identity its recipient was made from). Fetched
        # every boot: it only matters when tailscaled needs to log in, and a
        # headscale that is not up yet is retried, not fatal.
        systemd.services.tailnet-authkey = lib.mkIf (cfg.recipient != null) {
          description = "pre-auth key for the tailnet, from headscale";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          unitConfig.RequiresMountsFor = [ (dirOf hostKey.path) ];
          path = [
            pkgs.curl
            pkgs.age
            pkgs.ssh-to-age
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = 10;
            RuntimeDirectory = "tailnet";
            RuntimeDirectoryMode = "0700";
            UMask = "0077";
          };
          script = ''
            cd "$RUNTIME_DIRECTORY"
            curl -fsS --retry 3 -o authkey.age ${loginServer}${keysPath}${node}.age
            age -d -i <(ssh-to-age -private-key -i ${hostKey.path}) -o authkey authkey.age
          '';
        };

        # nixpkgs' unit runs `tailscale up` once; headscale may not be up yet,
        # or the key not fetched. It only logs in when the backend needs it,
        # so this is safe on a node that already joined.
        systemd.services.tailscaled-autoconnect = lib.mkIf (cfg.recipient != null) {
          after = [ "tailnet-authkey.service" ];
          wants = [ "tailnet-authkey.service" ];
          serviceConfig = {
            Restart = "on-failure";
            RestartSec = 10;
            RemainAfterExit = true;
          };
        };
      };
    };
in
{
  flake.nixosModules.ark-tailnet = tailnetModule;

  ark.services.headscale = {
    port = 8080;
    domain = "vpn.${ark.mainDomain}";
    oidc = {
      displayName = "VPN";
      callbacks = [ "/oidc/callback" ];
      owner = "headscale";
    };

    nixos =
      {
        service,
        config,
        lib,
        pkgs,
        ...
      }:
      {
        # The user, and a pre-auth key per tailnet node, every boot,
        # idempotently: minted (and the previous one expired) for a node
        # without one or with a new recipient, encrypted to the recipient and
        # kept only as that ciphertext, which nginx serves below.
        systemd.services.headscale-provision = {
          description = "headscale user and the nodes' pre-auth keys";
          wantedBy = [ "multi-user.target" ];
          after = [ "headscale.service" ];
          requires = [ "headscale.service" ];
          path = [
            config.services.headscale.package
            pkgs.jq
            pkgs.age
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "headscale";
            Group = "headscale";
            Restart = "on-failure";
            RestartSec = 5;
            StateDirectory = baseNameOf keysDir;
            StateDirectoryMode = "0755";
          };
          script = ''
            users() { headscale users list -o json; }
            users | jq -e '.[] | select(.name == "${tailnetUser}")' >/dev/null || headscale users create ${tailnetUser}
            uid=$(users | jq -r '.[] | select(.name == "${tailnetUser}") | .id')

            cd ${keysDir}
            mkdir -p pub
            while read -r node recipient; do
              if [ -s "pub/$node.age" ] && [ "$(cat "$node.recipient" 2>/dev/null)" = "$recipient" ]; then
                continue
              fi
              if [ -s "$node.id" ]; then
                echo "expiring the previous key of $node"
                headscale preauthkeys expire --id "$(cat "$node.id")"
              fi
              echo "minting a pre-auth key for $node"
              created=$(headscale preauthkeys create --user "$uid" --reusable --expiration 87600h -o json)
              jq -r .key <<<"$created" | age -r "$recipient" -o "pub/$node.age.tmp"
              jq -r .id <<<"$created" >"$node.id"
              printf '%s\n' "$recipient" >"$node.recipient"
              mv "pub/$node.age.tmp" "pub/$node.age"
            done <<'NODES'
            ${lib.concatStrings (lib.mapAttrsToList (node: recipient: "${node} ${recipient}\n") tailnetNodes)}NODES
          '';
        };

        services.headscale = {
          enable = true;
          address = "127.0.0.1"; # only nginx talks to it directly
          port = service.port;
          settings = {
            server_url = "https://${service.domain}";
            dns = {
              magic_dns = true;
              base_domain = "net.${ark.mainDomain}"; # must NOT equal server_url's domain
              override_local_dns = false;
              # Every other service lives on ark, so its names (and aliases)
              # resolve to ark's tailnet address inside the tailnet.
              extra_records = map (name: {
                inherit name;
                type = "A";
                value = arkTailnetIp;
              }) (lib.concatLists (lib.attrValues (builtins.removeAttrs ark.serviceDomains [ "headscale" ])));
            };
            prefixes = {
              v4 = "100.64.0.0/10";
              v6 = "fd7a:115c:a1e0::/48";
            };
            derp.server = {
              enabled = true;
              region_id = 999;
              region_code = "vps";
              region_name = "My VPS";
              stun_listen_addr = "0.0.0.0:3478";
            };

            oidc = {
              # kanidm is only reachable through the tailnet (nginx streams id.* to
              # 100.64.0.1), and the tailnet needs headscale up to admit this host.
              # Don't let an unreachable IdP be fatal, or the two deadlock on a
              # cold bootstrap. systemd restarts pick OIDC up once tailscale is up.
              only_start_if_oidc_is_available = false;
              issuer = service.oidc.issuer;
              client_id = service.oidc.clientId;
              client_secret_path = service.oidc.clientSecretFile;
              scope = service.oidc.scopes;
              allowed_groups = [ service.oidc.groups.members.claim ];
              pkce.enabled = true; # matches kanidm's default PKCE enforcement
            };
          };
        };

        services.nginx = {
          enable = true;
          # recommendedProxySettings = true;

          virtualHosts."${service.domain}" = {
            enableACME = true;
            forceSSL = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
              {
                addr = "[::]";
                port = 80;
              }
              {
                addr = "127.0.0.1";
                port = 8444;
                ssl = true;
              }
            ];
            locations."/" = {
              proxyPass = "http://127.0.0.1:${toString service.port}";
              proxyWebsockets = true; # required — clients use long-lived connections
            };
            # The nodes' encrypted pre-auth keys (headscale-provision above).
            locations.${keysPath} = {
              alias = "${keysDir}/pub/";
              extraConfig = ''
                default_type application/octet-stream;
              '';
            };
          };

          streamConfig = ''
            map $ssl_preread_server_name $backend {
            ${publicMap}  default  https_local;
            }

            ${publicUpstreams}
            upstream https_local {
              server 127.0.0.1:8444;
            }

            server {
              listen 443;
              listen [::]:443;
              proxy_pass $backend;
              ssl_preread on;
            }
          '';

          # The regular HTTPS vhosts (headscale) move to an internal port
          defaultSSLListenPort = 8444;
        };

        security.acme = {
          acceptTerms = true;
          defaults.email = "housemaster@${ark.mainDomain}";
        };

        # This host is a node too (den.aspects.headscale below): its key
        # exists once provisioned, and reaches it through its own nginx.
        systemd.services.tailnet-authkey = lib.mkIf (config.ark.tailnet.recipient != null) {
          after = [
            "headscale-provision.service"
            "nginx.service"
          ];
          wants = [ "headscale-provision.service" ];
        };

        networking.firewall.allowedTCPPorts = [
          80
          443
        ];
        # For direct connections / NAT traversal help:
        networking.firewall.allowedUDPPorts = [ 3478 ]; # STUN, if you enable the embedded DERP server
      };
  };

  # A host on the tailnet: its ssh host key, as ark.hostKey already names
  # it, is the identity it joins with.
  den.aspects.tailnet.nixos =
    { config, lib, ... }:
    {
      imports = [ tailnetModule ];
      ark.tailnet.recipient = lib.mkDefault config.ark.hostKey;
    };

  # The host-specific half: DNS for the vps that runs it — its own name,
  # plus every public name it fronts for ark.
  den.aspects.headscale =
    { host, ... }:
    {
      includes = [
        config.den.aspects.service-headscale
        config.den.aspects.tailnet
      ];

      dns_records = map (name: {
        inherit name;
        domain = ark.mainDomain;
        type = "A";
        content = ark.vps.ip host;
      }) ([ "vpn" ] ++ lib.attrNames ark.public);
    };
}
