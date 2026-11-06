# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# mail-aliases, against nixpkgs' SQLite rather than the copy rusqlite bundles
# for the rest of the workspace: the mail host builds its own system, and
# compiling sqlite3.c there (2 GB, no swap) crashed the C compiler.
{
  callPackage,
  sqlite,
  pkg-config,
}:
(callPackage ../../../_rust.nix { pname = "mail-aliases"; }).overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ sqlite ];
  nativeBuildInputs = old.nativeBuildInputs ++ [ pkg-config ];
})
