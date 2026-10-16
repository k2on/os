# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix flake check` / `nix build .#checks.<system>.pass-vaults`: runs
# test/run.sh inside the sandbox, against a real Vaultwarden on loopback.
{
  lib,
  runCommand,
  vaultwarden,
  pass-vaults,
  curl,
  jq,
  openssl,
}:
runCommand "pass-vaults-e2e"
  {
    nativeBuildInputs = [
      vaultwarden
      pass-vaults
      curl
      jq
      openssl
    ];
    src = lib.fileset.toSource {
      root = ./.;
      fileset = ./test;
    };
  }
  ''
    export HOME=$TMPDIR WORK=$TMPDIR/work
    bash $src/test/run.sh
    touch $out
  ''
