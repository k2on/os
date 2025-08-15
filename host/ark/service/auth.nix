{ config, pkgs, ... }: {
  services.pocket-id = {
    enable = true;
    settings = {
      APP_URL = "https://auth.koon.us";
      TRUST_PROXY = true;
      ANALYTICS_DISABLED = true;

      UI_CONFIG_DISABLED = true;

      APP_NAME = config.oauth.name;
    };
  };
}
