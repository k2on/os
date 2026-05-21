{ ... }: {
  perSystem = { pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      shellHook = ''
        export SOPS_AGE_KEY="$(${pkgs.age-plugin-yubikey}/bin/age-plugin-yubikey --identity)"
      '';

      packages = with pkgs; [
        age
        ssh-to-age
        sops
        just
        nix-inspect

        age-plugin-yubikey
      ];
    };
  };
}
