# ark-thunderbird (./src): readies a Thunderbird profile before it starts,
# against the NSS Thunderbird seals passwords with. Its tests (sealing in a
# new key store and opening it again among them) run in the build
# (`nix flake check`).
{
  perSystem =
    { pkgs, ... }:
    let
      ark-thunderbird =
        (pkgs.callPackage ../_rust.nix { pname = "ark-thunderbird"; }).overrideAttrs
          (old: {
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.nss ];
          });
    in
    {
      packages = { inherit ark-thunderbird; };
      checks = { inherit ark-thunderbird; };
    };
}
