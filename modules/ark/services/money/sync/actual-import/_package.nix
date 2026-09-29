# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# actual-import (TypeScript, src/), on the official @actual-app/api. That
# package must match the server it talks to (budget files carry migrations),
# so its version in package.json follows the money host's actual-server
# (adam builds from nixpkgs-unstable); the module asserts they agree and the
# check tests against that same server. To bump: edit package.json, then from
# this directory
#   npm install --package-lock-only --ignore-scripts
#   prefetch-npm-deps package-lock.json   # -> npmDepsHash
{
  lib,
  buildNpmPackage,
  nodejs_22,
  python3,
  sqlite,
  srcOnly,
  removeReferencesTo,
}:
let
  nodejs = nodejs_22; # what nixpkgs builds actual-server with
  nodeSources = srcOnly nodejs;
  manifest = lib.importJSON ./package.json;
in
buildNpmPackage {
  pname = "actual-import";
  version = manifest.version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
      ./tsconfig.json
      ./src
    ];
  };

  inherit nodejs;
  npmDepsHash = "sha256-YrAys573lC/AJms6fTH39BrGLBDejrdJhwZCtRY9fRI=";

  # `npm run build` is tsc: src/ -> dist/. better-sqlite3's install script
  # downloads a prebuilt binary; it is compiled from source below instead,
  # against this nodejs's headers.
  npmFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [
    python3
    sqlite
    removeReferencesTo
  ];

  postInstall = ''
    pushd $out/lib/node_modules/actual-import/node_modules/better-sqlite3
    npm run build-release --offline --nodedir="${nodeSources}"
    rm -rf build/Release/{.deps,obj,obj.target,test_extension.node}
    find build -type f -exec remove-references-to -t "${nodeSources}" {} \;
    popd
  '';

  passthru.actualVersion = manifest.dependencies."@actual-app/api";

  meta = {
    description = "Apply a money-sync change set to Actual Budget";
    mainProgram = "actual-import";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
