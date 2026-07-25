{ self, ... }: {
  flake.nixosModules.koonMaxSops = { config, ... }: {
    sops = {
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      defaultSopsFile = "${self}/secrets/koon/max/default.yaml";

      validateSopsFiles = false;

      secrets = {
        "yubico/u2f_keys" = {
          owner = config.users.users.max.name;
          inherit (config.users.users.max) group;
          path = "/home/max/.config/Yubico/u2f_keys";
        };
        "ssh_keys/max" = {
          owner = config.users.users.max.name;
          inherit (config.users.users.max) group;
          path = "/home/max/.ssh/id_maxkey";
          mode = "0600";
        };
        "waka_config" = {
          owner = config.users.users.max.name;
          inherit (config.users.users.max) group;
          path = "/home/max/.wakatime.cfg";
        };

        "proton_key" = {};
      };

    };
    environment.sessionVariables.PROTON_PASS_ENCRYPTION_KEY = config.sops.secrets.proton_key.path;
  };
}
