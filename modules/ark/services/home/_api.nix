# How Home Assistant's REST API takes an access token, for whoever calls it
# with one (sivrad wraps it as `home-api`, services/sivrad/_guest.nix):
# the API's path under the service's URL, and the Authorization header the
# token goes in. The token itself comes from ./_tokens.nix.
{
  path = "/api";
  header = "Authorization: Bearer";
}
