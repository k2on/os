{ ... }:
{
  den.aspects.dns = {
    terranix = {
      resource.porkbun_dns_record = {
        apex = {
          domain = "redactedaddress.com";
          # name = "";
          type = "A";
          content = "\${hcloud_server.vps.ipv4_address}";
          ttl = 600;
        };
      };
    };
  };
}
