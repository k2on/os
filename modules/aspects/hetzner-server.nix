{ ... }:
{
  den.aspects.hetzner-server = { host, ... }: {
    terranix = {
      resource.hcloud_server.${host.name} = {
        name = host.hostName;
        server_type = host.server-type;
        location = host.region;
        image = host.image;
        ssh_keys = [ "\${hcloud_ssh_key.default.id}" ];

        labels = {
          managed-by = "den-terranix";
        };
      };
    };
  };
}
