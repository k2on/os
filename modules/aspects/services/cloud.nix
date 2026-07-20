{ ... }: {
  ark.services.cloud = { service, pkgs, config, ... }: {
    environment.etc."nextcloud-admin-pass".text = "password123456789";
    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud33;
      hostName = "cloud.koon.us";
      https = true;
      config.adminpassFile = "/etc/nextcloud-admin-pass";
      config.dbtype = "sqlite";
      extraApps = {
        inherit (config.services.nextcloud.package.packages.apps) mail contacts calendar tasks;
      };
      extraAppsEnable = true;
      settings = {
        overwriteprotocol = "https";
        overwrite.cli.url = "https://cloud.example.com";
        trusted_proxies = [ "127.0.0.1" ];
      };
    };
    services.nginx.virtualHosts."cloud.koon.us".listen = [
      { addr = "127.0.0.1"; port = service.port; }
    ];
  };
}

