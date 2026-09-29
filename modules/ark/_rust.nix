# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# Builds one member of the Rust workspace in this directory (Cargo.toml):
#   pkgs.callPackage ./_rust.nix { pname = "ark"; }
# The whole workspace is the source, so the members can share files (the
# services' cli/ code is compiled into `ark`; money-sync borrows plaid.rs).
# Dependencies come from Cargo.lock; `cargo update` here and rebuild.
{
  lib,
  rustPlatform,
  pname,
}:
rustPlatform.buildRustPackage {
  inherit pname;
  version = (lib.importTOML ./Cargo.toml).workspace.package.version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.difference (lib.fileset.fileFilter (
      f: f.hasExt "rs" || f.name == "Cargo.toml" || f.name == "Cargo.lock"
    ) ./.) (lib.fileset.maybeMissing ./target);
  };
  cargoLock.lockFile = ./Cargo.lock;

  cargoBuildFlags = [
    "-p"
    pname
  ];
  cargoTestFlags = [
    "-p"
    pname
  ];

  meta.mainProgram = pname;
}
