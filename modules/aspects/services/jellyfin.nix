{ ... }: {
  ark.services.jellyfin = { ... }: {
    services.jellyfin = {
      enable = true;
      openFirewall = true;
    };
  };
}
