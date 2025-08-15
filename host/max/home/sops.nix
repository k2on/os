{ ... }:
{
  sops = {

    age.keyFile = "/home/max/.config/sops/age/keys.txt";

    defaultSopsFile = ../../../secrets/sops/host/max/default.yaml;
    validateSopsFiles = false;

    secrets = {
      "ssh_keys/max" = {
        path = "/home/max/.ssh/id_maxkey";
      };
      "waka_config" = {
        path = "/home/max/.wakatime.cfg";
      };
    };
  };
}
