# Wakatime's config, with its API key: a secret of Max's home
# (lib/secrets.nix), decrypted into ~/.wakatime.cfg when he signs in.
{ ... }:
{
  den.aspects.max.homeManager =
    { config, ... }:
    {
      ark.secrets.waka_config.path = "${config.home.homeDirectory}/.wakatime.cfg";
    };
}
