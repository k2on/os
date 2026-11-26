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
    # A laptop: closed is not down.
    alwaysOn = false;
    # Its person, whose home (homes/max) den puts in its home-manager.
    users.max.classes = [ "homeManager" ];
  };

  den.aspects.${name} = {
    includes = with den.aspects; [
      (asahi._.firmware ./firmware)
      gui
      kanidm-client
    ];

    # His local account's password (a hash, ./user.nix). His other secrets
    # are his home's own (lib/secrets.nix).
    secrets.max-password.neededForUsers = true;

    nixos = {
      imports = [
        ./_hardware-configuration.nix
        self.nixosModules.koonMaxConfiguration
      ];

      home-manager = {
        # A home brings its own nixpkgs settings (homes/max), as it does on
        # its own (homeConfigurations.max), rather than the host's.
        useGlobalPkgs = false;
        useUserPackages = true;
      };

      # Its age recipient (ssh-to-age of the host's ed25519 key), for the
      # secrets its aspects declare (lib/secrets.nix).
      ark.hostKey = "age1xvd63fqayxsjssn7ax7sayr3s49s295lwle8peffpa83tayygpuqkvvlqt";
    };
  };
}
