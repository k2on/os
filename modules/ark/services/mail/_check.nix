# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# `nix build .#checks.<system>.mail`: test/run.sh against a real Stalwart
# on loopback, with the settings benj runs (./_settings.nix). Paths only
# known at run time are @WORK@ in the config, filled in by the script.
#
# Stalwart's accounts come from `mail-aliases render` (./aliases), as on
# benj; the test makes aliases through its API like Bitwarden does, and
# restarts Stalwart after each change as benj does.
#
# The relay (TEM on benj) is relay.test.example, which does not resolve
# here: the check sees mail for the outside world head for it rather than
# for the recipient's MX. Logging in to TEM over TLS is not tested here,
# because Stalwart never relays to a loopback address, and loopback is all
# the sandbox has.
{
  lib,
  runCommand,
  formats,
  stalwart,
  mail-aliases,
  curl,
  openssl,
}:
let
  work = "@WORK@";
  person = name: groups: {
    inherit name groups;
    address = "${name}@test.example";
    passwordFile = "${work}/${name}.pw";
    tokenFile = "${work}/${name}.token";
  };
  aliases = (formats.json { }).generate "aliases.json" {
    db = "${work}/aliases.db";
    changedFile = "${work}/changed";
    domain = "test.example";
    listen = "127.0.0.1:12480";
    internalListen = "127.0.0.1:12481";
    internalKeyFile = "${work}/internal.key";
    persons = [
      (person "alice" [ "family" ])
      (person "bob" [ "family" ])
      (person "carol" [ ])
    ];
    groups = [
      {
        name = "family";
        address = "family@test.example";
      }
    ];
  };
  settings = import ./_settings.nix {
    hostname = "mail.test.example";
    domains = [ "test.example" ];
    listen = {
      smtp = "127.0.0.1:12525";
      submissions = "127.0.0.1:12465";
      imaps = "127.0.0.1:12993";
    };
    relay = {
      address = "relay.test.example";
      port = 2465;
      usernameFile = "${work}/relay.user";
      passwordFile = "${work}/relay.pw";
    };
    certFile = "${work}/cert.pem";
    keyFile = "${work}/key.pem";
    spamFilter = "file://${stalwart.spam-filter}/spam-filter.toml";
  };
  # What the NixOS module adds on benj, and checks needing DNS off: the
  # sandbox has none.
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
      resolver.type = "system";
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
      mail-aliases
      curl
      openssl
    ];
    CONFIG = config;
    ALIASES = aliases;
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
