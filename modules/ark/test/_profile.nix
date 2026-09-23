# The test profile: what turns a production host module list into a node of
# the ark VM test (test/vm.nix). Everything that reaches outside the test
# network is swapped for a fixture inside it:
#
#   secrets   sops files generated at build time, encrypted to test/age.key,
#             holding "test-<key>" for every declared secret; the same key on
#             every node, so a value shared between hosts still matches.
#   DNS       the `dns` node (pebble-challtestsrv) answers every name; it also
#             takes the DNS-01 TXT records, so the wildcard ACME cert is issued
#             for real by the `acme` node (pebble) with a test CA every node
#             trusts.
#   hardware  disks and bootloader come from the test framework.
#
# Nothing here changes what a service does, only where it looks things up.
{
  ark,
  lib,
  ageKey,
}:
{
  config,
  pkgs,
  nodes,
  ...
}:
let
  # kanidm's host owns the wildcard cert (aspects/acme.nix); the other hosts
  # get theirs per virtual host over HTTP-01, which pebble serves as is.
  hasWildcard = config.services.kanidm.server.enable;
  dnsIp = nodes.dns.networking.primaryIPAddress;
  agePub = lib.head (
    lib.filter (l: lib.hasPrefix "age1" l) (
      map (lib.removePrefix "# public key: ") (lib.splitString "\n" (builtins.readFile ageKey))
    )
  );

  # One sops file per ark secret key, plus the host's legacy defaultSopsFile
  # with every sops secret name in it. Encrypted at build time; sops needs
  # no network for that.
  arkKeys = lib.unique (lib.mapAttrsToList (_: s: s.key) config.ark.secrets);
  legacyKeys = lib.unique (lib.mapAttrsToList (_: s: s.key) config.sops.secrets);
  testVars =
    pkgs.runCommand "ark-test-vars"
      {
        nativeBuildInputs = [ pkgs.sops ];
        inherit arkKeys legacyKeys;
      }
      ''
        mkdir -p $out/vars
        for key in $arkKeys; do
          printf '%s: test-%s\n' "$key" "$key" > "$out/vars/$key.yaml"
        done
        for key in $legacyKeys; do
          printf '%s: test-%s\n' "$key" "$key" >> "$out/default.yaml"
        done
        touch "$out/default.yaml"
        for f in $out/vars/*.yaml $out/default.yaml; do
          [ -s "$f" ] || continue
          sops --encrypt --age ${agePub} --in-place "$f"
        done
      '';

  # lego's exec provider, pointed at challtestsrv's TXT API.
  dnsHook = pkgs.writeShellScript "acme-dns-hook" ''
    set -euo pipefail
    if [ "$1" = "present" ]; then
      ${pkgs.curl}/bin/curl -sS --data @- http://dns.test:8055/set-txt <<EOF
      {"host": "$2", "value": "$3"}
    EOF
    else
      ${pkgs.curl}/bin/curl -sS --data @- http://dns.test:8055/clear-txt <<EOF
      {"host": "$2"}
    EOF
    fi
  '';
in
{
  # What nixos/tests/common/acme/client does, minus its email, which the
  # host already sets.
  security.acme.defaults.server = lib.mkForce "https://${nodes.acme.test-support.acme.caDomain}/dir";
  security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];

  ark.varsDir = "${testVars}/vars";
  ark.checkVars = false;

  sops = {
    defaultSopsFile = lib.mkForce "${testVars}/default.yaml";
    validateSopsFiles = false;
    age = {
      # sops-nix refuses a store path here, so the key is copied out first.
      keyFile = lib.mkForce "/run/ark-test-age.key";
      sshKeyPaths = lib.mkForce [ ];
      generateKey = lib.mkForce false;
    };
    gnupg.sshKeyPaths = lib.mkForce [ ];
  };

  system.activationScripts = lib.mkMerge [
    {
      arkTestAgeKey.text = "install -m 0400 ${ageKey} /run/ark-test-age.key";
      setupSecrets.deps = [ "arkTestAgeKey" ];
    }
    # sops-nix only defines this script when a secret is needed for users
    (lib.mkIf (lib.any (s: s.neededForUsers) (lib.attrValues config.sops.secrets)) {
      setupSecretsForUsers.deps = [ "arkTestAgeKey" ];
    })
  ];

  networking.nameservers = lib.mkForce [ dnsIp ];

  security.acme.certs = lib.mkIf hasWildcard {
    ${ark.mainDomain} = {
      dnsProvider = lib.mkForce "exec";
      dnsResolver = lib.mkForce "${dnsIp}:53";
      dnsPropagationCheck = false;
      environmentFile = lib.mkForce (
        pkgs.writeText "acme-exec.env" ''
          EXEC_PATH=${dnsHook}
          EXEC_POLLING_INTERVAL=1
          EXEC_PROPAGATION_TIMEOUT=1
          EXEC_SEQUENCE_INTERVAL=1
        ''
      );
    };
  };

  environment.systemPackages = [
    pkgs.curl
    pkgs.dig
  ];

  virtualisation = {
    memorySize = if hasWildcard then 4096 else 2048;
    diskSize = 16384;
    cores = 2;
  };
}
