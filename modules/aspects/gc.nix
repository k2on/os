# The same clean-up on every host: once a week, the last 5 generations of
# each system profile are kept and the rest of the store that nothing uses is
# deleted. Two profiles: comin's (system-profiles/comin, what deploys make;
# it keeps 5 itself too, aspects/deploy.nix) and the plain system one (what a
# `nixos-rebuild` by hand makes). The boot menu offers the same 5. A host
# that was off when it was due cleans up when it next starts. Then the store
# is deduplicated (nix.optimise).
{ den, lib, ... }:
let
  keep = 5;
in
{
  den.default.includes = [
    (
      { host, ... }:
      lib.optionalAttrs (host ? class && host.class == "nixos") {
        nixos =
          { config, ... }:
          {
            nix.gc = {
              automatic = true;
              dates = "weekly";
              persistent = true;
            };
            systemd.services.nix-gc.preStart = ''
              for profile in /nix/var/nix/profiles/system /nix/var/nix/profiles/system-profiles/comin; do
                if [ -e "$profile" ]; then
                  ${config.nix.package}/bin/nix-env --profile "$profile" --delete-generations +${toString keep}
                fi
              done
            '';

            # Then identical files in the store become one (hard links), after
            # the collection so as not to spend it on what is about to go.
            nix.optimise = {
              automatic = true;
              dates = [ "weekly" ];
            };
            systemd.services.nix-optimise.after = [ "nix-gc.service" ];

            boot.loader.systemd-boot.configurationLimit = lib.mkDefault keep;
            boot.loader.grub.configurationLimit = lib.mkDefault keep;
          };
      }
    )
  ];
}
