{ ... }:
{
  den.aspects.security = {
    nixos = {
      security.pki.caCertificateBlacklist = [
        "Comodo AAA Services root"
        "emSign ECC Root CA - G3"
      ];
    };
  };
}
