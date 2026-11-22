# ark-dav (./src): the calendars and address books a person sees in
# Radicale, as JSON. Its tests run in the build (`nix flake check`).
{
  perSystem =
    { pkgs, ... }:
    let
      ark-dav = pkgs.callPackage ../_rust.nix { pname = "ark-dav"; };
    in
    {
      packages = { inherit ark-dav; };
      checks = { inherit ark-dav; };
    };
}
