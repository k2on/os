# YubiKeys: their own apps, smart-card access and udev rules.
{ ... }:
{
  den.aspects.gui.nixos =
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [
        yubioath-flutter # gui
        yubikey-manager # `ykman`
      ];

      services.pcscd.enable = true;
      services.udev.packages = [ pkgs.yubikey-personalization ];

      services.yubikey-agent.enable = true;

      # Signing in and sudo are by password only: no YubiKey (pam_u2f) and
      # no ssh agent key in PAM.
    };
}
