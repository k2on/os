{ ... }:
{
  ark.services.waka =
    { service, ... }:
    {
      services.wakapi = {
        enable = true;
        # passwordSaltFile = config.sops.secrets."waka-password-salt".path;
        settings = {
          server.port = service.port;
          # app.avatar_url_template = "";
        };
      };
    };
}
