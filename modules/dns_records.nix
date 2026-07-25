{ ... }:
{
  den.aspects.ark = {
    dns_records = [
      {
        domain = "redactedaddress.com";
        name = "headscale";
        type = "A";
        content = "\${hcloud_server.vps.ipv4_address}";
      }
      {
        domain = "redactedaddress.com";
        name = "";
        type = "A";
        content = "\${hcloud_server.vps.ipv4_address}";
      }
      # {
      #   domain = "koon.us";
      #   name = "id";
      #   type = "A";
      #   content = "\${hcloud_server.vps.ipv4_address}";
      # }
    ];
  };
}
