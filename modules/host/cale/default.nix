# cale: Max's laptop (Apple silicon), as a den host so it can take aspects
# like the others (`just rebuild` builds .#cale); the machine's own setup
# stays in koonMaxConfiguration (./configuration.nix).
{
  self,
  inputs,
  den,
  ...
}:
let
  # This folder's name: the host's, its flake output's and its hostname.
  name = baseNameOf ./.;
in
{
  den.hosts.aarch64-linux.${name} = {
    instantiate = inputs.nixpkgs.lib.nixosSystem;
    color = "#f9e2af"; # yellow
  };

  den.aspects.${name} = {
    includes = with den.aspects; [
      avatar
      codex
      security
      deploy
      kanidm-client
    ];

    nixos = {
      imports = [
        self.inputs.nixos-apple-silicon.nixosModules.apple-silicon-support
        self.inputs.sops-nix.nixosModules.sops
        self.inputs.home-manager.nixosModules.home-manager
        self.nixosModules.koonMaxConfiguration
      ];

      # Its age recipient (ssh-to-age of the host's ed25519 key), for the
      # secrets its aspects declare (lib/secrets.nix).
      ark.hostKey = "age1xvd63fqayxsjssn7ax7sayr3s49s295lwle8peffpa83tayygpuqkvvlqt";
    };
  };
}
