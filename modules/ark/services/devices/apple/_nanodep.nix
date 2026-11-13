# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# nanodep (github.com/micromdm/nanodep), the client for Apple's Automated
# Device Enrollment (Apple Business Manager's "MDM servers"): depserver
# keeps the tokens and proxies Apple's DEP API, depsyncer follows the
# devices assigned to the server and gives new ones a profile. Not in
# nixpkgs, so built here.
{ buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "nanodep";
  version = "0.7.0";

  src = fetchFromGitHub {
    owner = "micromdm";
    repo = "nanodep";
    rev = "v${version}";
    hash = "sha256-PzK4u8+J+dvFm9CQAVsDM/1MJgZAsDCJE0viwgRGooo=";
  };

  vendorHash = "sha256-QEajlZMtRZiz838yT+LGoJqNSqe9gVlYY77BF7kqDnw=";

  subPackages = [
    "cmd/depserver"
    "cmd/depsyncer"
  ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta.mainProgram = "depserver";
}
