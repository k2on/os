{ config, lib, ... }:
{
  sops = {

    age.keyFile = if builtins.pathExists /var/lib/sops-nix/key.txt then
      "/var/lib/sops-nix/key.txt"
    else
      "/home/max/.config/sops/age/keys.txt" # temp decrypt key
    ;

    defaultSopsFile = ../../secrets/sops/host/max/default.yaml;
    validateSopsFiles = false;

    secrets = {
      "host_age_key" = {
        path = "/var/lib/sops-nix/key.txt";
      };
      "yubico/u2f_keys" = {
        owner = config.users.users.max.name;
        inherit (config.users.users.max) group;
        path = "/home/max/.config/Yubico/u2f_keys";
      };
      "proton_key" = {};
    };

  };

  environment.sessionVariables.PROTON_PASS_ENCRYPTION_KEY = config.sops.secrets.proton_key.path;
}
