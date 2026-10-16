# The proxy as a package: `nix build .#llm-proxy`. Its users build it the
# same way (the sivrad container's model, Codex on a workstation via
# aspects/codex.nix).
{
  perSystem =
    { pkgs, ... }:
    {
      packages.llm-proxy = pkgs.callPackage ../_rust.nix { pname = "llm-proxy"; };
    };
}
