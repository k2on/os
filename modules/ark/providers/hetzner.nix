{ ... }:
let
  orDefault = value: default: if value != null then value else default;
in
{
  ark.vps.providers.hetzner = {
    secrets.HCLOUD_TOKEN = { };

    # Offline test: servers get documentation addresses instead of random strings.
    mock.hcloud.mock_resource.hcloud_server.defaults = {
      ipv4_address = "203.0.113.10";
      ipv6_address = "2001:db8::1";
    };

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
