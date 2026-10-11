# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix flake check` / `nix build .#checks.<system>.sivrad-channel`: runs
# test/run.sh inside the sandbox, where loopback is all the network there
# is and all it needs: the channel, a stand-in for the agent's app-server
# and for Kanidm's userinfo endpoint (test/fake.py, Python's standard
# library), and curl as the phone.
{
  lib,
  runCommand,
  sivrad-channel,
  python3,
  curl,
  jq,
}:
runCommand "sivrad-channel-e2e"
  {
    nativeBuildInputs = [
      sivrad-channel
      python3
      curl
      jq
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
