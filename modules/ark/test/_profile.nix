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
  system,
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
  isHeadscale = config.services.headscale.enable;
  isClient = config.services.tailscale.enable && !hasWildcard && !isHeadscale;
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
        # sops-nix reads "a/b" as the nested key a.b; JSON is YAML enough for sops
        ${pkgs.python3}/bin/python3 - $legacyKeys > "$out/default.yaml" <<'EOF'
        import json, sys
        tree = {}
        for key in sys.argv[1:]:
            node = tree
            parts = key.split("/")
            for part in parts[:-1]:
                node = node.setdefault(part, {})
            node[parts[-1]] = "test-" + key
        print(json.dumps(tree))
        EOF
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
  # hosts outside den have no host key; the test key stands in
  ark.hostKey = lib.mkDefault agePub;

  # Every member joins with the shared key; a host that logs in interactively
  # in production (a laptop, through OIDC) gets the key here so it can join
  # unattended. Members of den.aspects.tailnet already have both.
  ark.secrets.headscale_preauth_key = { };
  services.tailscale.authKeyFile = lib.mkIf config.services.tailscale.enable (
    lib.mkDefault config.sops.secrets.headscale_preauth_key.path
  );

  # One test, one architecture: hosts that are aarch64 in production run as
  # the test's system here (their hardware modules are switched off by
  # test/vm.nix).
  nixpkgs.hostPlatform = system;
  boot.binfmt.emulatedSystems = lib.mkForce [ ];

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

  # Production's kanidm host holds the first tailnet address (the vps
  # streams id.* to it). Here every host joins at boot, so headscale's own
  # host waits for another node before it joins, and every other member
  # waits until the identity provider answers through the vps, which is the
  # order production reached too.
  systemd.services.tailscaled-autoconnect.preStart = lib.mkMerge [
    (lib.mkIf isHeadscale ''
      until [ "$(${config.services.headscale.package}/bin/headscale nodes list -o json | ${pkgs.jq}/bin/jq length)" -gt 0 ]; do
        sleep 2
      done
    '')
    (lib.mkIf isClient ''
      until ${pkgs.curl}/bin/curl -sSf --max-time 10 https://id.${ark.mainDomain}/status >/dev/null 2>&1; do
        sleep 5
      done
    '')
  ];

  environment.systemPackages = [
    pkgs.curl
    pkgs.dig
  ];

  virtualisation = {
    memorySize =
      if hasWildcard then
        4096
      else if config.hardware.graphics.enable then
        3072
      else
        2048;
    diskSize = 16384;
    cores = 2;
  };
}
