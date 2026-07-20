{ self, ... }: {
  flake.nixosModules.vps-sops = { ... }: {
    sops = {
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      validateSopsFiles = false;

      secrets = {
        "headscale_oidc_client_secret" = {
          owner = "headscale";
          sopsFile = "${self}/secrets/sops/oidc/headscale.yaml";
        };
      };
    };
  };
}

