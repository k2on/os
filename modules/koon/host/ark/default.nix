{ self, inputs, ... }: {
  flake.nixosConfigurations.koonArk = inputs.nixpkgs-unstable.lib.nixosSystem {
    modules = [
      self.inputs.sops-nix.nixosModules.sops
      self.nixosModules.koonArkConfiguration
    ];
  };
}
