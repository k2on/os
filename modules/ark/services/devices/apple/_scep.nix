# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# scep (github.com/micromdm/scep), the SCEP server that hands each Apple
# device enrolling with nanohub (./_nanohub.nix) the identity certificate it
# signs its MDM check-ins with; scepclient comes along for testing it.
# nixpkgs' sscep is only a client, so built here.
{ buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "scep";
  version = "2.3.0";

  src = fetchFromGitHub {
    owner = "micromdm";
    repo = "scep";
    rev = "v${version}";
    hash = "sha256-guATCYcTgiedZxBpp3ye7OvgjJV6Qe+dQujuvrwAnKs=";
  };

  vendorHash = "sha256-ZqewHnNolp89epb2a31ZJGx1Nazx4tGg+cS1Yamut8E=";

  subPackages = [
    "cmd/scepserver"
    "cmd/scepclient"
  ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta.mainProgram = "scepserver";
}
