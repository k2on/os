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
# virtual host over TLS, then builds the tailnet the way production does:
# kanidm's host joins the headscale on the vps first (so it gets 100.64.0.1,
# the address the vps streams id.<domain> to), the vps joins, and the
# identity provider is fetched through that path.
#
# Layer 1 (lib/tftest.nix) checks the terraform side offline; this is the
# NixOS side. Neither talks to a provider.
{ lib, config, ... }:
let
  cfg = config.ark.test;
  nixosConfigs = config.flake.nixosConfigurations;
  profile = import ./_profile.nix {
    inherit lib;
    ark = config.ark;
    ageKey = ./age.key;
  };

  denHosts = lib.concatMap lib.attrValues (lib.attrValues config.den.hosts);
  hostByName =
    name: lib.findFirst (h: h.name == name) (throw "ark.test: no den host '${name}'") denHosts;

  # A host node is the host's own modules plus the profile. The host's own
  # nixpkgs (den's instantiate) is what the test framework should use too.
  # The test framework provides the disk; disko's layout would wait for
  # partitions that do not exist, so hosts installed by disko turn it off.
  hostNode = name: {
    imports =
      nixosConfigs.${name}._module.args.modules
      ++ [ profile ]
      ++ lib.optional (nixosConfigs.${name}.options ? disko) { disko.enableConfig = lib.mkForce false; };
  };

  fqdn = r: if r.name == "" then r.domain else "${r.name}.${r.domain}";

  mkTest =
    pkgs:
    pkgs.testers.runNixOSTest (
      { nodes, ... }:
      let
        ipOf = name: nodes.${name}.networking.primaryIPAddress;

        # hostnames every host serves over TLS, resolved to that host
        vhosts = lib.concatMap (
          name:
          map (vhost: {
            host = vhost;
            ip = ipOf name;
          }) (lib.filter (v: v != "_") (lib.attrNames nodes.${name}.services.nginx.virtualHosts))
        ) cfg.hosts;

        # provider reference -> test address, for hosts in the test
        refs = lib.listToAttrs (
          map (
            name:
            let
              h = hostByName name;
            in
            lib.nameValuePair (config.ark.vps.ip h) (ipOf name)
          ) (lib.filter (name: (hostByName name).provider or null != null) cfg.hosts)
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

        # the tailnet: kanidm's host and the headscale host, when both are in
        kanidmHost = lib.findFirst (n: nodes.${n}.services.kanidm.server.enable) null cfg.hosts;
        headscaleHost = lib.findFirst (n: nodes.${n}.services.headscale.enable) null cfg.hosts;
        withTailnet = kanidmHost != null && headscaleHost != null;
        loginServer = nodes.${headscaleHost}.services.headscale.settings.server_url;
        idUrl = "https://id.${config.ark.mainDomain}";
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
        // lib.genAttrs cfg.hosts hostNode;

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
            ${name}.wait_for_unit("nginx.service")
            ${name}.wait_for_open_port(443)
          '') cfg.hosts}

          with subtest("every virtual host answers over TLS"):
              ${lib.concatMapStringsSep "\n    " (
                v:
                ''assert int(${lib.head cfg.hosts}.succeed("curl -sS -o /dev/null -w '%{http_code}' --max-time 60 https://${v.host}/")) < 500, "${v.host} answered 5xx"''
              ) vhosts}
          ${lib.optionalString withTailnet ''

            with subtest("the tailnet forms and reaches the identity provider through it"):
                ${headscaleHost}.wait_for_unit("headscale.service")
                ${headscaleHost}.succeed("headscale users create test")
                authkey = ${headscaleHost}.succeed("headscale preauthkeys --user 1 create --reusable").strip()
                up = f"tailscale up --login-server '${loginServer}' --auth-key {authkey}"
                # kanidm's host first: production streams id.* to the first tailnet address
                ${kanidmHost}.succeed(up)
                ${kanidmHost}.wait_until_succeeds("tailscale ip -4")
                ${headscaleHost}.succeed(up)
                ${headscaleHost}.wait_until_succeeds("tailscale ping 100.64.0.1")
                ${kanidmHost}.wait_for_unit("kanidm.service")
                assert ${headscaleHost}.wait_until_succeeds("curl -sS --max-time 30 ${idUrl}/status").strip() == "true"
          ''}
        '';
      }
    );
in
{
  options.ark.test.hosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "adam"
      "vps"
    ];
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
