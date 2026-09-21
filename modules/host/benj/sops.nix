{ self, ... }:
{
  flake.nixosModules.vps-sops =
    { pkgs, ... }:
    {
      ark.hostKey = "age1qttkn8kcl3v35n77ee8fcqsh0kvux3tpknnfu4azk7pl76fvsfkqe7uc7y";

      sops = {
        age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

        validateSopsFiles = false;

        # Go 1.26's runtime corrupts its own heap under the qemu-user emulation
        # this x86_64 host is built through from aarch64, so sops-install-secrets
        # — the only compiled derivation left in the closure — fails to build.
        # 1.25 is unaffected; drop this once 1.26 survives emulation.
        package = (pkgs.callPackage self.inputs.sops-nix { }).sops-install-secrets.override {
          buildGoModule = pkgs.buildGoModule.override { go = pkgs.go_1_25; };
        };
      };
    };
}
