# Install and deploy a host with nixos-anywhere. Provider-agnostic: where
# the machine is and how to reach it come from ark.vps (lib/vps.nix).
{ config, ... }:
{
  den.aspects.nixos-deploy =
    { host, ... }:
    {
      terranix = {
        module.deploy = {
          source = "github.com/nix-community/nixos-anywhere//terraform/all-in-one";
          nixos_system_attr = ".?submodules=1#nixosConfigurations.${host.name}.config.system.build.toplevel";
          nixos_partitioner_attr = ".?submodules=1#nixosConfigurations.${host.name}.config.system.build.diskoScript";
          target_host = config.ark.vps.ip host;
          instance_id = config.ark.vps.id host;
          build_on_remote = true;
          debug_logging = true;
        };
      };
    };
}
