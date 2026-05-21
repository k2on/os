{ self, inputs, ... }: {
  flake.nixosConfigurations.koonMax = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.inputs.nixos-apple-silicon.nixosModules.apple-silicon-support
      self.inputs.sops-nix.nixosModules.sops
      self.inputs.home-manager.nixosModules.home-manager
      self.nixosModules.koonMaxConfiguration
    ];
  };
}

