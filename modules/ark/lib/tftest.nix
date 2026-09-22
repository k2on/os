# Offline test of the generated infra, as `checks.infra-tftest`.
#
# `tofu test` runs the same configuration `ark plan` uses, with every
# provider replaced by an OpenTofu mock (no API calls, no tokens) and the
# nixos-anywhere module replaced by its outputs. A plan and a mocked apply
# must both succeed, which is where broken references, duplicate resources
# and misconfigured providers show up, and then the test asserts the
# provider-agnostic contract every host relies on: ark.vps.ip / ark.vps.id
# resolve to a real resource for each host that declares a provider, and
# every DNS record ends up with content.
#
# Nothing here emulates Hetzner or Cloudflare. That is what the VM
# integration test is for; this layer is cheap enough to run on every push.
#
# Provider mocks come from ark.vps.providers.<p>.mock and
# ark.dns.providers.<p>.mock (lib/vps.nix, lib/dns.nix), keyed by the
# terraform provider's local name.
{
  lib,
  config,
  inputs,
  ...
}:
let
  # terraform reference "${a.b.c}" -> expression "a.b.c"
  deref = s: lib.removeSuffix "}" (lib.removePrefix "\${" s);

  # a terraform source address "owner/name" -> nixpkgs terraform-providers attr
  pluginAttr =
    source:
    let
      parts = lib.splitString "/" source;
      n = builtins.length parts;
    in
    lib.concatStringsSep "_" (lib.sublist (n - 2) 2 parts);

  # Providers pulled in by nixos-anywhere's modules; not in the root
  # config's required_providers, so tofu init cannot learn them from it.
  nixosAnywherePlugins = [
    "hashicorp_null"
    "hashicorp_external"
  ];

  hosts = lib.concatMap lib.attrValues (lib.attrValues config.den.hosts);
  vpsHosts = lib.filter (h: (h.provider or null) != null) hosts;

  providerMocks = lib.foldl' lib.recursiveUpdate { } (
    map (p: p.mock) (lib.attrValues config.ark.vps.providers ++ lib.attrValues config.ark.dns.providers)
  );

  # terranix core, as the locked terranix exposes it. Older releases take
  # the configuration as one module (`terranix_config`), newer ones a list.
  core = import "${inputs.terranix}/core/default.nix";
  evalInfra =
    pkgs:
    let
      modules = config.ark.infra.modules;
      args =
        if (builtins.functionArgs core) ? terranix_config then
          { terranix_config.imports = modules; }
        else
          { inherit modules; };
    in
    (core ({ inherit pkgs; } // args)).config;

  mkCheck =
    pkgs:
    let
      infra = evalInfra pkgs;
      json = pkgs.formats.json { };

      requiredProviders = infra.terraform.required_providers or { };
      providerNames = lib.attrNames requiredProviders;

      # nixpkgs ships one version per provider; the constraints in
      # required_providers are for the real run, not for the mocks.
      testConfig = infra // {
        terraform = infra.terraform // {
          required_providers = lib.mapAttrs (_: p: builtins.removeAttrs p [ "version" ]) requiredProviders;
        };
      };

      tofu = pkgs.opentofu.withPlugins (
        p:
        map (name: p.${name}) (
          map (n: pluginAttr requiredProviders.${n}.source) providerNames ++ nixosAnywherePlugins
        )
      );

      assertRef = ref: message: {
        condition = "\${${deref ref} != \"\"}";
        error_message = message;
      };

      hostAsserts = lib.concatMap (h: [
        (assertRef (config.ark.vps.ip h) "host '${h.name}': ark.vps.ip resolves to nothing on provider '${h.provider}'")
        (assertRef (config.ark.vps.id h) "host '${h.name}': ark.vps.id resolves to nothing on provider '${h.provider}'")
      ]) vpsHosts;

      recordAsserts = lib.concatLists (
        lib.mapAttrsToList (
          type: records:
          lib.mapAttrsToList (
            name: _: assertRef "\${${type}.${name}.content}" "dns record ${type}.${name} has no content"
          ) records
        ) (lib.filterAttrs (type: _: lib.hasSuffix "_dns_record" type) (infra.resource or { }))
      );

      tftest = {
        mock_provider = lib.recursiveUpdate (lib.genAttrs providerNames (_: { })) providerMocks;
        override_module = map (name: {
          target = "module.${name}";
          outputs.result.out = "/nix/store/00000000000000000000000000000000-mock-toplevel";
        }) (lib.attrNames (infra.module or { }));
        run = {
          plan.command = "plan";
          apply = {
            command = "apply";
            "assert" = hostAsserts ++ recordAsserts;
          };
        };
      };
    in
    pkgs.runCommand "infra-tftest"
      {
        nativeBuildInputs = [ tofu ];
        configJson = json.generate "config.tf.json" testConfig;
        testJson = json.generate "infra.tftest.json" tftest;
      }
      ''
        export HOME="$TMPDIR" TF_IN_AUTOMATION=1 TF_INPUT=0
        mkdir -p work/tests
        cp "$configJson" work/config.tf.json
        cp "$testJson" work/tests/infra.tftest.json
        ln -s ${inputs.nixos-anywhere}/terraform work/nixos-anywhere
        cd work
        # withPlugins points tofu at its plugin dir, so init never touches the network
        tofu init -backend=false
        tofu test
        touch "$out"
      '';
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        infra-tftest = mkCheck pkgs;
      };
    };
}
