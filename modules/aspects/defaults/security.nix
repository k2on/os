# Trust: certificate authorities no host should accept. Every NixOS host
# has it.
{ den, ... }:
{
  den.schema.host.includes = [ den.aspects.security ];

  den.aspects.security = {
    nixos = {
      security.pki.caCertificateBlacklist = [
        "Comodo AAA Services root"
        "emSign ECC Root CA - G3"
      ];
    };
  };
}
