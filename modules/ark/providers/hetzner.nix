{ ... }:
let
  orDefault = value: default: if value != null then value else default;
in
{
  ark.vps.providers.hetzner = {
    secrets.HCLOUD_TOKEN = { };

    static = {
      terraform.required_providers.hcloud = {
        source = "hetznercloud/hcloud";
        version = "~> 1.45";
      };
      provider.hcloud = { };

      resource.hcloud_ssh_key.default = {
        name = "my-ssh-key";
        public_key = builtins.readFile ../../aspects/key.pub;
      };
    };

    server = host: {
      resource.hcloud_server.${host.name} = {
        name = host.hostName;
        server_type = orDefault host.server-type "cx22";
        location = orDefault host.region "fsn1";
        image = orDefault host.image "ubuntu-24.04";
        ssh_keys = [ "\${hcloud_ssh_key.default.id}" ];

        labels = {
          managed-by = "den-terranix";
        };
      };
    };

    ip = host: "\${hcloud_server.${host.name}.ipv4_address}";
    id = host: "\${hcloud_server.${host.name}.id}";
  };
}
