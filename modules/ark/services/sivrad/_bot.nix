# The `sivrad` account: a Kanidm person the assistant signs in to services
# with, and the services it may use. Shared by the pieces that make it so:
# ./_kanidm.nix (the person and its password), ./default.nix (its group
# memberships, what the container is told), ./_host.nix (what the container
# sees) and each service's _tokens.nix, which mints that service's API token
# for it into tokensDir. Underscore: not a flake module.
rec {
  name = "sivrad";
  displayName = "Sivrad";
  mail = domain: "${name}@${domain}";
  # The services it may use. It joins each one's members group in Kanidm
  # (<service>_members, lib/oidc.nix), and each one's _tokens.nix puts a
  # token for it in tokensDir.
  services = [
    "home"
    "git"
  ];
  # On adam: one file per service, named after it, plus `password`, the
  # Kanidm password. World-readable in a directory nobody can list: the
  # readers are services on adam and the sivrad container, which bind-mounts
  # the directory as /run/host-tokens (./_host.nix).
  tokensDir = "/var/lib/sivrad-tokens";
  token = service: "${tokensDir}/${service}";
  # The TOTP Kanidm enrols for the account (./_kanidm.nix checks it is this
  # kind), as oathtool spells it: `oathtool --totp=sha256 ...`.
  totp = {
    algo = "sha256";
    step = 30;
    digits = 6;
  };
}
