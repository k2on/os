{ ... }: {
  ark.services.auth = { config, service, ... }: {
    services.pocket-id = {
      enable = true;
      settings = {
        PORT = service.port;
        APP_URL = "https://auth.koon.us";
        TRUST_PROXY = true;
        ANALYTICS_DISABLED = true;

        UI_CONFIG_DISABLED = true;

        APP_NAME = "KoonFamily";
      };

      credentials = {
        ENCRYPTION_KEY = config.sops.secrets."pocket-id-encryption-key".path;
      };
    };
  };
}

