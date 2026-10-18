# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix build .#checks.<system>.mail`: test/run.sh against a real Stalwart
# on loopback, with the settings benj runs (./_settings.nix). Paths only
# known at run time are @WORK@ in the config, filled in by the script.
{
  lib,
  runCommand,
  formats,
  stalwart,
  curl,
  openssl,
}:
let
  work = "@WORK@";
  person = name: memberOf: {
    inherit name memberOf;
    address = "${name}@test.example";
    passwordFile = "${work}/${name}.pw";
  };
  settings = import ./_settings.nix {
    hostname = "mail.test.example";
    mailboxes = [
      (person "alice" [ "family" ])
      (person "bob" [ "family" ])
      (person "carol" [ ])
    ];
    shared = [
      {
        name = "family";
        address = "family@test.example";
      }
    ];
    listen = {
      smtp = "127.0.0.1:12525";
      submissions = "127.0.0.1:12465";
      imaps = "127.0.0.1:12993";
    };
    certFile = "${work}/cert.pem";
    keyFile = "${work}/key.pem";
    spamFilter = "file://${stalwart.spam-filter}/spam-filter.toml";
  };
  # What the NixOS module adds on benj, and no DNS: the sandbox has none.
  config = (formats.toml { }).generate "stalwart.toml" (
    lib.recursiveUpdate settings {
      store.db = {
        type = "rocksdb";
        path = "${work}/db";
      };
      storage = {
        data = "db";
        fts = "db";
        lookup = "db";
        blob = "db";
      };
      tracer.stdout = {
        type = "stdout";
        level = "info";
        ansi = false;
        enable = true;
      };
      resolver = {
        type = "custom";
        custom = [ "udp://127.0.0.1:1" ];
      };
      # Stalwart takes mail without a login on port 25 only; 12525 stands in.
      session.auth.require = [
        {
          "if" = "local_port == 12525";
          "then" = false;
        }
        { "else" = true; }
      ];
      spam-filter.enable = false;
      auth = {
        spf.verify.ehlo = "disable";
        spf.verify.mail-from = "disable";
        dmarc.verify = "disable";
        arc.verify = "disable";
        dkim.verify = "disable";
        iprev.verify = "disable";
      };
    }
  );
in
runCommand "mail-e2e"
  {
    nativeBuildInputs = [
      stalwart
      curl
      openssl
    ];
    CONFIG = config;
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
