# The power key is the Touch ID key, beside delete: pressed by mistake, it
# should not turn the Mac off.
{ ... }:
{
  den.aspects.asahi.nixos.services.logind.settings.Login.HandlePowerKey = "ignore";
}
