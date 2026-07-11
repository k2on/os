{ ... }:
{
  den.aspects.nixos-deploy = { host, ... }: {
    terranix = {
      module.deploy = {
        source = "github.com/nix-community/nixos-anywhere//terraform/all-in-one";
        nixos_system_attr      = ".#nixosConfigurations.${host.name}.config.system.build.toplevel";
        nixos_partitioner_attr = ".#nixosConfigurations.${host.name}.config.system.build.diskoScript";
        target_host      = "\${hcloud_server.${host.name}.ipv4_address}";
        instance_id      = "\${hcloud_server.${host.name}.id}";
        build_on_remote  = true;
        debug_logging  = true;
      };
    };
  };
}
