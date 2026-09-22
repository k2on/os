# The ark as a NixOS VM test, as `checks.ark-vm`.
#
# Every host in ark.test.hosts boots as a node from the same module list its
# nixosConfigurations entry is built from, plus test/_profile.nix, on one test
# network with a `dns` node (pebble-challtestsrv: answers every name, takes
# DNS-01 challenges) and an `acme` node (pebble with a test CA). The test
# waits for each host's services and fetches every nginx virtual host over
# TLS through that DNS and that CA.
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

  # A host node is the host's own modules plus the profile. The host's own
  # nixpkgs (den's instantiate) is what the test framework should use too.
  hostNode = name: {
    imports = nixosConfigs.${name}._module.args.modules ++ [ profile ];
  };

  mkTest =
    pkgs:
    pkgs.testers.runNixOSTest (
      { nodes, ... }:
      let
        # hostnames every host serves over TLS, resolved to that host
        vhosts = lib.concatMap (
          name:
          let
            node = nodes.${name};
          in
          map (vhost: {
            inherit vhost;
            ip = node.networking.primaryIPAddress;
          }) (lib.filter (v: v != "_") (lib.attrNames node.services.nginx.virtualHosts))
        ) cfg.hosts;
        firstHost = nodes.${lib.head cfg.hosts};
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
                  ExecStart = "${pkgs.pebble}/bin/pebble-challtestsrv -dns01 ':53' -http01 '' -https01 '' -tlsalpn01 '' -defaultIPv6 '' -defaultIPv4 '${firstHost.networking.primaryIPAddress}'";
                  AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
                };
              };
              # Every node's names, and the CA, on top of the default answer.
              systemd.services.ark-test-records = {
                description = "register test DNS records";
                wantedBy = [ "multi-user.target" ];
                after = [ "pebble-challtestsrv.service" ];
                requires = [ "pebble-challtestsrv.service" ];
                serviceConfig.Type = "oneshot";
                serviceConfig.RemainAfterExit = true;
                script =
                  lib.concatMapStringsSep "\n"
                    (
                      r:
                      "${pkgs.curl}/bin/curl -sS --retry 10 --retry-connrefused --data '${
                        builtins.toJSON {
                          inherit (r) host;
                          addresses = [ r.ip ];
                        }
                      }' http://localhost:8055/add-a"
                    )
                    (
                      [
                        {
                          host = nodes.acme.test-support.acme.caDomain;
                          ip = nodes.acme.networking.primaryIPAddress;
                        }
                      ]
                      ++ map (v: {
                        host = v.vhost;
                        inherit (v) ip;
                      }) vhosts
                    );
              };
            };

          acme =
            { modulesPath, ... }:
            {
              imports = [ "${modulesPath}/../tests/common/acme/server" ];
              networking.nameservers = lib.mkForce [ nodes.dns.networking.primaryIPAddress ];
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
            ${name}.wait_for_unit("acme-finished-${config.ark.mainDomain}.target")
            ${name}.wait_for_unit("nginx.service")
            ${name}.wait_for_open_port(443)
          '') cfg.hosts}

          with subtest("every virtual host answers over TLS"):
              ${lib.concatMapStringsSep "\n    " (
                v:
                ''assert int(${lib.head cfg.hosts}.succeed("curl -sS -o /dev/null -w '%{http_code}' --max-time 60 https://${v.vhost}/")) < 500, "${v.vhost} answered 5xx"''
              ) vhosts}
        '';
      }
    );
in
{
  options.ark.test.hosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "adam" ];
    description = "Hosts (nixosConfigurations names) that boot in the VM test.";
  };

  config.perSystem =
    { system, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        ark-vm = mkTest nixosConfigs.${lib.head cfg.hosts}.pkgs;
      };
    };
}
