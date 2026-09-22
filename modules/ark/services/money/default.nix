{ ... }:
{
  ark.services.money = {
    oidc = {
      callbacks = [ "/openid/callback" ];
      # actual's openid client may not send a PKCE challenge; this lets
      # kanidm accept it either way. Flip to true once confirmed it does.
      pkce = false;
      # actual's openid client rejects kanidm's ES256 tokens ("expected RS256").
      legacyCrypto = true;
      owner = "actual";
    };

    nixos =
      { service, ... }:
      {
        # A fixed user instead of the module's DynamicUser: the config is
        # rendered in preStart by that user, so it must be able to read the
        # client secret file.
        users.users.actual = {
          isSystemUser = true;
          group = "actual";
        };
        users.groups.actual = { };

        services.actual = {
          enable = true;
          user = "actual";
          group = "actual";
          settings = {
            hostname = "127.0.0.1"; # only nginx talks to it
            port = service.port;

            # Login only through kanidm. Anyone kanidm lets in (money_members)
            # gets an actual account on first login; the budget owner then
            # grants them access to the shared budget once, in the UI
            # (Settings -> Show advanced settings -> User access). Actual has
            # no config for sharing a budget file, so that step stays manual.
            loginMethod = "openid";
            allowedLoginMethods = [ "openid" ];
            userCreationMode = "login";
            openId = {
              discoveryURL = service.oidc.discovery;
              client_id = service.oidc.clientId;
              client_secret._secret = service.oidc.clientSecretFile;
              server_hostname = "https://${service.domain}";
              authMethod = "openid";
            };
          };
        };
      };
  };
}
