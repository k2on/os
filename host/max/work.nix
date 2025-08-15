{ config, secrets, ... }: {


  services.openvpn.servers = {
    ris = {
      config = "config /etc/openvpn/ris/config.ovpn ";
      updateResolvConf = true;
      autoStart = false;
    };
  };

  sops.secrets = {
      "ris-vpn/key" = {
        sopsFile = ../../secrets/sops/host/max/work.yaml;
        owner = config.users.users.root.name;
        inherit (config.users.users.root) group;
        path = "/etc/openvpn/ris/vpnclient.rismedia.com.key";
      };
  };

  environment.etc."openvpn/ris/config.ovpn" = {
    text = secrets.work.ris.vpn.config;
  };
  environment.etc."openvpn/ris/vpnclient.rismedia.com.crt" = {
    text = secrets.work.ris.vpn.crt;
  };

  networking.extraHosts = ''
    ${secrets.work.ris.extraHosts}
  '';
}
