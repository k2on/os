# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix build .#checks.<system>.apple-devices-metrics`: metrics/test/run.sh,
# apple-devices-metrics against nanohub's and NanoDEP's APIs as static files
# on loopback in the sandbox.
{
  lib,
  runCommand,
  apple-devices-metrics,
  busybox,
  openssl,
  curl,
}:
runCommand "apple-devices-metrics-e2e"
  {
    nativeBuildInputs = [
      apple-devices-metrics
      openssl
      curl
    ];
    # By its path: on PATH its date and base64 would replace coreutils'.
    BUSYBOX = "${busybox}/bin/busybox";
    src = lib.fileset.toSource {
      root = ./metrics;
      fileset = ./metrics/test;
    };
  }
  ''
    export HOME=$TMPDIR
    bash $src/test/run.sh
    touch $out
  ''
