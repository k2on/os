# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix build .#checks.<system>.apple-enroll`: enroll/test/run.sh, a signed
# MachineInfo POSTed to apple-enroll on loopback in the sandbox.
{
  lib,
  runCommand,
  apple-enroll,
  openssl,
  curl,
}:
runCommand "apple-enroll-e2e"
  {
    nativeBuildInputs = [
      apple-enroll
      openssl
      curl
    ];
    src = lib.fileset.toSource {
      root = ./enroll;
      fileset = ./enroll/test;
    };
  }
  ''
    export HOME=$TMPDIR
    bash $src/test/run.sh
    touch $out
  ''
