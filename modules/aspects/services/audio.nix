{ ... }: {
  ark.services.audio = { service, ... }: {
    services.audiobookshelf = {
      enable = true;
      port = service.port;
    };
  };
}
