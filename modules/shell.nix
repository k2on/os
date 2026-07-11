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
            HCLOUD_TOKEN=$(${pkgs.sops}/bin/sops -d --extract '["hetzner-api-token"]' secrets/infra-providers.yaml) nix run .#vps.apply
          }

          # @cmd Destroy internet infra
          infra::destroy () {
            HCLOUD_TOKEN=$(${pkgs.sops}/bin/sops -d --extract '["hetzner-api-token"]' secrets/infra-providers.yaml) nix run .#vps.destroy
          }

          # @cmd Install NixOS on vps
          infra::deploy () {
            IP=$(${pkgs.opentofu}/bin/tofu -chdir=modules/host/vps/infra output -raw vps_ip)
            nix run github:nix-community/nixos-anywhere -- \
              --flake .#vps \
              --build-on-remote \
              --generate-hardware-config nixos-generate-config \
                ./modules/host/vps/_hardware-configuration.nix \
              root@$IP
          }

          eval "$(${pkgs.argc}/bin/argc --argc-eval "$0" "$@")"
        '')
      ];
    };
  };
}
