{ ... }:
{
  den.aspects.money = {
    secrets = [
      {
        name = "oauth_secret";
      }
    ];

    nixos.services.actual = {
      enable = true;
      # settings.port = service.port;
    };
  };
}
