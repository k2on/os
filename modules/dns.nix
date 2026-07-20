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
        headscale = {
          domain = "redactedaddress.com";
          name = "headscale";
          type = "A";
          content = "\${hcloud_server.vps.ipv4_address}";
          ttl = 600;
        };
      };

      data.cloudflare_zone.main = {
        filter.name = "koon.us";
      };

      resource.cloudflare_dns_record = {
        id = {
          zone_id = "\${data.cloudflare_zone.main.id}";
          name = "id";
          type = "A";
          content = "\${hcloud_server.vps.ipv4_address}";
          ttl = 600;
        };
      };
    };
  };
}
