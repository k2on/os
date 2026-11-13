# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# nanohub (github.com/micromdm/nanohub), the MDM server for the household's
# Apple devices: NanoMDM's protocol handling with its command queue,
# declarative management (KMFDDM) and the DEP sync bundled into one binary.
# Not in nixpkgs, so built here.
{ buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "nanohub";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "micromdm";
    repo = "nanohub";
    rev = "v${version}";
    hash = "sha256-7D11Ze+pW6adU7dD4lKp/WwlbHT4Dv1DjI0mHKMyPss=";
  };

  vendorHash = "sha256-Qd5VpRUKiumVASkl9ophsVlcBieC3uSUi9Ay/G4IwhA=";

  subPackages = [ "cmd/nanohub" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta.mainProgram = "nanohub";
}
