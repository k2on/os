# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix build .#checks.<system>.photos-avatars`: test/run.sh against a real
# Postgres (the major version Immich's runs on adam) on a socket in the
# sandbox.
{
  lib,
  runCommand,
  postgresql,
  photos-avatars,
  curl,
  imagemagick,
}:
runCommand "photos-avatars-e2e"
  {
    nativeBuildInputs = [
      postgresql
      photos-avatars
      curl
      imagemagick
    ];
    KEEP = ./keep.sh;
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
