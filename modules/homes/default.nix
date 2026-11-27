# Every person who may sign in to a desktop (ark.login.desktop.members) has
# a home, made of what every desktop home has
# (aspects/gui/home) and their own aspect (homes/<person>), if they have one.
# A desktop carries each one's recipe, unbuilt, and builds only the home of
# whoever signs in (aspects/gui/homes.nix).
#
# Each is made for every platform a desktop may be (Apple silicon, PCs):
# homeConfigurations."<person>-<system>"; a desktop takes those of its own.
{
  self,
  config,
  lib,
  den,
  ...
}:
let
  members = config.ark.login.desktop.members;
  systems = [
    "aarch64-linux"
    "x86_64-linux"
  ];
in
{
  den.homes = lib.genAttrs systems (
    system:
    lib.genAttrs members (name: {
      intoAttr = [
        "homeConfigurations"
        "${name}-${system}"
      ];
    })
  );

  # Whose home it is: their account, from Kanidm, has /home/<name> (a link to
  # /home/<uuid>), which is what home-manager checks $HOME against.
  den.schema.home.includes = [ den.aspects.home-account ];
  den.aspects.home-account =
    { home, ... }:
    {
      homeManager =
        { lib, ... }:
        {
          home.username = home.userName;
          home.homeDirectory = "/home/${home.userName}";
          # The release a home starts on; one made earlier keeps its own.
          home.stateVersion = lib.mkDefault "26.05";
        };
    };

  perSystem =
    { system, ... }:
    {
      checks = lib.optionalAttrs (lib.elem system systems) (
        lib.listToAttrs (
          map (name: {
            name = "home-${name}";
            value = self.homeConfigurations."${name}-${system}".activationPackage;
          }) members
        )
      );
    };
}
