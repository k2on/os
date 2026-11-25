# Secrets (lib/secrets.nix, which brings in sops-nix for every host): each
# host decrypts its own with its ssh host key, whose age form is its
# ark.hostKey.
{ ... }:
{
  den.schema.host.includes = [
    { nixos.sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]; }
  ];
}
