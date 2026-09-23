# The ark as a NixOS VM test, as `checks.ark-vm`.
#
# Every host in ark.test.hosts boots as a node from the same module list its
# nixosConfigurations entry is built from, plus test/_profile.nix, on one test
# network with a `dns` node (pebble-challtestsrv: answers every name, takes
# DNS-01 challenges) and an `acme` node (pebble with a test CA). The dns node
# serves every nginx virtual host of every host, and every dns_records entry
# whose content is a provider reference (ark.vps.ip) for a host in the test,
# resolved to that host's test address.
#
# The test waits for each host's certificates and nginx, fetches every
# virtual host over TLS, then watches the tailnet form on its own
# (den.aspects.tailnet joins every member at boot): kanidm's host gets
# 100.64.0.1, the address the vps streams id.<domain> to, the vps joins, and
# the identity provider is fetched through that path.
#
# Layer 1 (lib/tftest.nix) checks the terraform side offline; this is the
# NixOS side. Neither talks to a provider.
{ lib, config, ... }:
let
  cfg = config.ark.test;
  nixosConfigs = config.flake.nixosConfigurations;
  profile =
    system:
    import ./_profile.nix {
      inherit lib system;
      ark = config.ark;
      ageKey = ./age.key;
    };

  denHosts = lib.concatMap lib.attrValues (lib.attrValues config.den.hosts);
  # null for a nixosConfigurations entry declared outside den (the laptop)
  hostByName = name: lib.findFirst (h: h.name == name) null denHosts;

  # A host node is the host's own modules plus the profile. The host's own
  # nixpkgs (den's instantiate) is what the test framework should use too.
  # What a host's production hardware brings is switched off from outside,
  # since a module cannot set an option it may not have: disko's layout
  # would wait for partitions that do not exist, Apple Silicon support would
  # bring an aarch64 kernel. A host outside den gets ark's secrets module so
  # the profile can hand it the tailnet key.
  hostNode =
    system: name:
    let
      opts = nixosConfigs.${name}.options;
    in
    {
      imports =
        nixosConfigs.${name}._module.args.modules
        ++ [ (profile system) ]
        ++ lib.optional (opts ? disko) { disko.enableConfig = lib.mkForce false; }
        ++ lib.optional (opts.hardware ? asahi) { hardware.asahi.enable = lib.mkForce false; }
        ++ lib.optional (!(opts ? ark)) config.flake.nixosModules.ark-secrets;
    };

  fqdn = r: if r.name == "" then r.domain else "${r.name}.${r.domain}";

  mkTest =
    pkgs:
    pkgs.testers.runNixOSTest (
      { nodes, ... }:
      let
        ipOf = name: nodes.${name}.networking.primaryIPAddress;

        # public hostnames every host serves over TLS, resolved to that host
        # (internal names like localhost stay out of the test's DNS)
        vhosts = lib.concatMap (
          name:
          map
            (vhost: {
              host = vhost;
              ip = ipOf name;
            })
            (
              lib.filter (v: lib.hasSuffix ".${config.ark.mainDomain}" v) (
                lib.attrNames nodes.${name}.services.nginx.virtualHosts
              )
            )
        ) cfg.hosts;

        # provider reference -> test address, for hosts in the test
        refs = lib.listToAttrs (
          map (name: lib.nameValuePair (config.ark.vps.ip (hostByName name)) (ipOf name)) (
            lib.filter (name: (hostByName name).provider or null != null) cfg.hosts
          )
        );
        records = lib.concatMap (
          r:
          lib.optional (r.type == "A" && refs ? ${r.content}) {
            host = fqdn r;
            ip = refs.${r.content};
          }
        ) config.ark.infra.dnsRecords;

        dnsEntries = lib.unique (
          [
            {
              host = nodes.acme.test-support.acme.caDomain;
              ip = ipOf "acme";
            }
          ]
          ++ vhosts
          ++ records
        );

        # every host waits for all of its certificates
        certTargets =
          name: map (c: "acme-finished-${c}.target") (lib.attrNames nodes.${name}.security.acme.certs);
        serves = name: nodes.${name}.services.nginx.enable;

        # the tailnet: kanidm's host and the headscale host, when both are in
        kanidmHost = lib.findFirst (n: nodes.${n}.services.kanidm.server.enable) null cfg.hosts;
        headscaleHost = lib.findFirst (n: nodes.${n}.services.headscale.enable) null cfg.hosts;
        withTailnet = kanidmHost != null && headscaleHost != null;
        idUrl = "https://id.${config.ark.mainDomain}";
        # everyone else on the tailnet reaches services through it, by the
        # names headscale's extra_records give them
        clients = lib.filter (
          n: nodes.${n}.services.tailscale.enable && n != kanidmHost && n != headscaleHost
        ) cfg.hosts;
        viaTailnet = (lib.head (lib.filter (v: v.ip == ipOf kanidmHost) vhosts)).host;
      in
      {
        name = "ark-vm";

        # The hosts' modules set nixpkgs.* themselves.
        node.pkgs = lib.mkForce null;

        nodes = {
          dns =
            { pkgs, ... }:
            {
              networking = {
                hostName = "dns";
                domain = "test";
                firewall.allowedTCPPorts = [
                  53
                  8055
                ];
                firewall.allowedUDPPorts = [ 53 ];
              };
              systemd.services.pebble-challtestsrv = {
                description = "mock DNS and ACME challenge server";
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  ExecStart = "${pkgs.pebble}/bin/pebble-challtestsrv -dns01 ':53' -http01 '' -https01 '' -tlsalpn01 '' -defaultIPv6 '' -defaultIPv4 '${ipOf (lib.head cfg.hosts)}'";
                  AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
                };
              };
              systemd.services.ark-test-records = {
                description = "register test DNS records";
                wantedBy = [ "multi-user.target" ];
                after = [ "pebble-challtestsrv.service" ];
                requires = [ "pebble-challtestsrv.service" ];
                serviceConfig.Type = "oneshot";
                serviceConfig.RemainAfterExit = true;
                script = lib.concatMapStringsSep "\n" (
                  r:
                  "${pkgs.curl}/bin/curl -sS --retry 10 --retry-connrefused --data '${
                    builtins.toJSON {
                      inherit (r) host;
                      addresses = [ r.ip ];
                    }
                  }' http://localhost:8055/add-a"
                ) dnsEntries;
              };
            };

          acme =
            { modulesPath, ... }:
            {
              imports = [ "${modulesPath}/../tests/common/acme/server" ];
              networking.nameservers = lib.mkForce [ (ipOf "dns") ];
            };
        }
        // lib.genAttrs cfg.hosts (hostNode pkgs.stdenv.hostPlatform.system);

        testScript = ''
          dns.start()
          acme.start()
          dns.wait_for_unit("ark-test-records.service")
          acme.wait_for_unit("pebble.service")
          acme.wait_for_open_port(443)

          ${lib.concatMapStringsSep "\n" (name: ''
            ${name}.start()
            ${name}.wait_for_unit("multi-user.target")
            ${lib.concatMapStringsSep "\n" (t: "${name}.wait_for_unit(\"${t}\")") (certTargets name)}
            ${lib.optionalString (serves name) ''
              ${name}.wait_for_unit("nginx.service")
              ${name}.wait_for_open_port(443)
            ''}
          '') cfg.hosts}

          with subtest("every virtual host answers over TLS"):
              ${lib.concatMapStringsSep "\n    " (
                v:
                ''assert int(${lib.head cfg.hosts}.succeed("curl -sS -o /dev/null -w '%{http_code}' --max-time 60 https://${v.host}/")) < 500, "${v.host} answered 5xx"''
              ) vhosts}
          ${lib.optionalString withTailnet ''

            with subtest("the tailnet forms and reaches the identity provider through it"):
                ${headscaleHost}.wait_for_unit("headscale-provision.service")
                # every member joins on its own (den.aspects.tailnet); kanidm's
                # host first, since production streams id.* to the first address
                ${kanidmHost}.wait_for_unit("tailscaled-autoconnect.service")
                assert ${kanidmHost}.succeed("tailscale ip -4").strip() == "100.64.0.1"
                ${headscaleHost}.wait_for_unit("tailscaled-autoconnect.service")
                ${headscaleHost}.wait_until_succeeds("tailscale ping 100.64.0.1")
                ${kanidmHost}.wait_for_unit("kanidm.service")
                assert ${headscaleHost}.wait_until_succeeds("curl -sS --max-time 30 ${idUrl}/status").strip() == "true"

            with subtest("every other member joins and reaches services over the tailnet"):
                ${lib.concatStringsSep "\n    " (
                  lib.concatMap (c: [
                    "${c}.wait_for_unit(\"tailscaled-autoconnect.service\")"
                    "${c}.wait_until_succeeds(\"tailscale ping 100.64.0.1\")"
                    "assert ${c}.wait_until_succeeds(\"dig +short @100.100.100.100 ${viaTailnet}\").strip() == \"100.64.0.1\""
                    "assert int(${c}.succeed(\"curl -sS -o /dev/null -w '%{http_code}' --max-time 60 --resolve ${viaTailnet}:443:100.64.0.1 https://${viaTailnet}/\")) < 500"
                  ]) clients
                )}
          ''}
        '';
      }
    );
in
{
  options.ark.test.hosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = lib.attrNames nixosConfigs;
    defaultText = "every nixosConfigurations entry";
    description = "Hosts (nixosConfigurations names) that boot in the VM test; the first one is what unknown names resolve to.";
  };

  config.perSystem =
    { system, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        ark-vm = mkTest nixosConfigs.${lib.head cfg.hosts}.pkgs;
      };
    };
}
