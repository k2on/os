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
        opentofu

        (writeShellScriptBin "ark" ''
          # @describe CLI for the Koon Family Opperating System

          # @cmd Manage internet infra
          infra() { :; }

          # @cmd Plan out internet infra
          infra::plan() {
            ${pkgs.sops}/bin/sops exec-env secrets/infra-providers.yaml 'nix run .#infra.plan' 
          }

          # @cmd Generate internet infra
          infra::push () {
            ${pkgs.sops}/bin/sops exec-env secrets/infra-providers.yaml 'nix run .#infra.apply' 
          }

          # @cmd Destroy internet infra
          infra::destroy () {
            ${pkgs.sops}/bin/sops exec-env secrets/infra-providers.yaml 'nix run .#infra.destroy' 
          }

          eval "$(${pkgs.argc}/bin/argc --argc-eval "$0" "$@")"
        '')
      ];
    };
  };
}
