{ config, ... }:
let
  # The vps fronting redactedaddress.com, by its den host, so a rename follows.
  ip = config.ark.vps.ip config.den.hosts.x86_64-linux.benj;
in
{
  den.aspects.ark = {
    dns_records = [
      {
        domain = "redactedaddress.com";
        name = "headscale";
        type = "A";
        content = ip;
      }
      {
        domain = "redactedaddress.com";
        name = "";
        type = "A";
        content = ip;
      }
    ];
  };
}
