# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix flake check` / `nix build .#checks.<system>.money-sync`: runs test/run.sh
# inside the sandbox, where loopback is all the network there is and all it needs.
{
  lib,
  runCommand,
  actual-server,
  money-sync,
  actual-import,
  nodejs_22,
  sqlite,
}:
runCommand "money-sync-e2e"
  {
    nativeBuildInputs = [
      actual-server
      money-sync
      actual-import
      nodejs_22
      sqlite
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
