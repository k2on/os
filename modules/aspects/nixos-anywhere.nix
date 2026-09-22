# Install and deploy a host with nixos-anywhere. Provider-agnostic: where
# the machine is and how to reach it come from ark.vps (lib/vps.nix).
{ config, ... }:
{
  den.aspects.nixos-deploy =
    { host, ... }:
    {
      terranix = {
        module.deploy = {
          # Pinned by the nixos-anywhere flake input; the terranix wrapper
          # symlinks its terraform/ directory into the workdir (lib/terranix.nix).
          # It has to be a path inside the workdir: the all-in-one module
          # reaches its siblings with ../, which OpenTofu refuses from an
          # absolute store path ("local module path escapes module package").
          source = "./nixos-anywhere/all-in-one";
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
