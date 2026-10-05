# The `ark` CLI (../cli, Rust): on the dev shell's PATH (modules/shell.nix)
# and, through the home module below, installed for the people who run it so
# their zsh finds its completions.
#
# Repo-wide commands (plan/push/destroy/secrets) live in ../cli/src. A service
# adds `ark service <name> ...` by shipping ../services/<name>/cli/mod.rs with
# a `pub static SERVICE`; ../cli/build.rs finds it, nothing is registered by
# hand. Service commands read what they need from the flake through
# `nix eval`, e.g. money's `arkServiceConfig.money` output.
{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.ark = (pkgs.callPackage ../_rust.nix { pname = "ark"; }).overrideAttrs (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [
          pkgs.installShellFiles
          pkgs.makeWrapper
        ];
        # The tools ark shells out to ride along, so it works outside the dev
        # shell too (nix and git are on every host already).
        #
        # `COMPLETE=<shell> ark` prints the shell's completion shim (clap_complete);
        # at completion time the shim asks the binary itself, so this file never
        # goes stale. zsh picks it up from share/zsh/site-functions.
        postInstall = ''
          wrapProgram $out/bin/ark \
            --prefix PATH : ${
              pkgs.lib.makeBinPath [
                pkgs.sops
                pkgs.age-plugin-yubikey
              ]
            }
          installShellCompletion --cmd ark \
            --zsh <(COMPLETE=zsh $out/bin/ark) \
            --bash <(COMPLETE=bash $out/bin/ark) \
            --fish <(COMPLETE=fish $out/bin/ark)
        '';
      });
    };

  # home-manager: `ark` (and its completions) for a user's shell, wherever they
  # are; it still has to be run from inside a checkout of this repo.
  flake.homeModules.arkCli =
    { pkgs, ... }:
    {
      home.packages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.ark ];
    };
}
