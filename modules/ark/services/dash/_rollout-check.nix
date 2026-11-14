# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix build .#checks.<system>.ark-rollout`: rollout/test/run.sh, ark-rollout
# with git and nix stood in for, in the sandbox.
{
  lib,
  runCommand,
  ark-rollout,
}:
runCommand "ark-rollout-e2e"
  {
    nativeBuildInputs = [ ark-rollout ];
    src = lib.fileset.toSource {
      root = ./rollout;
      fileset = ./rollout/test;
    };
  }
  ''
    export HOME=$TMPDIR
    bash $src/test/run.sh
    touch $out
  ''
