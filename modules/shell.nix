{ ... }:
{
  perSystem =
    { pkgs, config, ... }:
    {
      devShells.default = pkgs.mkShell {
        # No SOPS_AGE_KEY here: `ark` asks the yubikey for its identity only when
        # something has to be decrypted, and asks you to plug it in if it is
        # not. So the shell works without the key, and `ark sops <file>` is the
        # way to run sops by hand.
        packages = with pkgs; [
          # `ark`: see modules/ark/lib/cli.nix. It shells out to nix, sops, git.
          config.packages.ark

          age
          ssh-to-age
          sops
          just
          jq
          nix-inspect

          age-plugin-yubikey
          opentofu
        ];
      };
    };
}
