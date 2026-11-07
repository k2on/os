# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# Builds one member of the Rust workspace in this directory (Cargo.toml):
#   pkgs.callPackage ./_rust.nix { pname = "ark"; }
# Dependencies come from Cargo.lock; `cargo update` here and rebuild. The
# .js files are what sivrad-browser embeds (include_str!).
#
# A member's source is its own directory, so changing one member rebuilds
# only that one: `ark` adds the services' cli/ code it compiles in
# (cli/build.rs). Cargo still reads every member's manifest, so all of them
# and Cargo.lock come along; the other members' code does not, and an empty
# main.rs stands in for it.
{
  lib,
  rustPlatform,
  pname,
}:
let
  inherit (lib) fileset;
  members = (lib.importTOML ./Cargo.toml).workspace.members;
  nameOf = dir: (lib.importTOML (./. + "/${dir}/Cargo.toml")).package.name;
  dir = lib.findFirst (d: nameOf d == pname) (throw "_rust.nix: no workspace member is named ${pname}") members;
  code = fileset.fileFilter (f: f.hasExt "rs" || f.hasExt "js");

  serviceClis = lib.filter builtins.pathExists (
    lib.mapAttrsToList (name: _: ./services + "/${name}/cli") (
      lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./services)
    )
  );
in
rustPlatform.buildRustPackage {
  inherit pname;
  version = (lib.importTOML ./Cargo.toml).workspace.package.version;

  src = fileset.toSource {
    root = ./.;
    fileset = fileset.unions (
      [
        ./Cargo.toml
        ./Cargo.lock
        (code (./. + "/${dir}"))
      ]
      ++ map (d: ./. + "/${d}/Cargo.toml") members
      ++ lib.optionals (dir == "cli") (map code serviceClis)
    );
  };
  cargoLock.lockFile = ./Cargo.lock;

  # The members left out: an empty main.rs each, so their manifests resolve,
  # and an empty build script where one is declared.
  postPatch = ''
    for m in ${lib.escapeShellArgs (lib.remove dir members)}; do
      mkdir -p "$m/src"
      [ -e "$m/src/main.rs" ] || [ -e "$m/src/lib.rs" ] || echo 'fn main() {}' > "$m/src/main.rs"
      build=$(sed -n 's/^build *= *"\(.*\)"/\1/p' "$m/Cargo.toml")
      if [ -n "$build" ] && [ ! -e "$m/$build" ]; then echo 'fn main() {}' > "$m/$build"; fi
    done
  '';

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
