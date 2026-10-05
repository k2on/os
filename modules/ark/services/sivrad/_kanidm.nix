# The phone's sign-in: a public OAuth2 client `sivrad` in adam's Kanidm (PKCE
# enforced, no client secret) that redirects to the app's custom scheme, and
# the group whose members may use it. The channel checks the resulting
# access token against the client's userinfo endpoint (./channel/src/oidc.rs).
{ origin, members }:
{
  services.kanidm.provision = {
    groups.sivrad_users = { inherit members; };
    systems.oauth2.sivrad = {
      public = true;
      displayName = "Sivrad";
      originUrl = "sivrad://oauth/callback";
      originLanding = origin;
      preferShortUsername = true;
      scopeMaps.sivrad_users = [
        "openid"
        "profile"
        "email"
        "groups"
      ];
    };
  };
}
