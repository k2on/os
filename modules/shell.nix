{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      devShells.default = pkgs.mkShell {
        shellHook = ''
          export SOPS_AGE_KEY="$(${pkgs.age-plugin-yubikey}/bin/age-plugin-yubikey --identity)"
        '';

        packages = with pkgs; [
          age
          ssh-to-age
          sops
          just
          jq
          nix-inspect

          age-plugin-yubikey
          opentofu

          (writeShellScriptBin "ark" ''
            # @describe CLI for the Koon Family Opperating System

            manifest() {
              nix eval --json '.?submodules=1#arkSecrets'
            }

            # Export the provider tokens (ark.infraSecrets) from secrets/vars.
            # One sops call per token, so one yubikey touch each.
            infra_env() {
              for key in $(manifest | jq -r '.infra[]'); do
                export "$key=$(${pkgs.sops}/bin/sops -d --extract "[\"$key\"]" "secrets/vars/$key.yaml")"
              done
            }

            # @cmd Plan out internet infra
            plan() {
              infra_env
              nix run ".?submodules=1#infra.plan"
            }

            # @cmd Generate internet infra
            push () {
              # terranix's generated apply script ends in a bare `tofu apply` and
              # never forwards "$@", so `-- -auto-approve` was silently dropped.
              # Answer the approval prompt on stdin instead.
              infra_env
              nix run ".?submodules=1#infra.apply"
            }

            # @cmd Destroy internet infra
            destroy () {
              infra_env
              nix run ".?submodules=1#infra.destroy"
            }

            # @cmd List every secret declared in nix; create the missing ones, rekey the changed ones
            # See modules/ark/lib/secrets.nix for the `secrets` quirk this reads.
            # @flag -n --dry-run  Only list what is missing or stale, change nothing
            secrets() {
              m=$(manifest)
              mkdir -p secrets/vars && cd secrets/vars
              # sops finds this .sops.yaml on its own from inside secrets/vars,
              # so `sops <key>.yaml` works here by hand as well.
              [ "$argc_dry_run" = 1 ] || jq .sopsConfig <<<"$m" > .sops.yaml
              printf '%-32s %-8s %-9s %s\n' SECRET STATE SOURCE HOSTS
              for key in $(jq -r '.secrets | keys[]' <<<"$m"); do
                file=$key.yaml
                want=$(jq -r ".secrets[\"$key\"].recipients[]" <<<"$m" | sort)
                gen=$(jq -r ".secrets[\"$key\"].generate // empty" <<<"$m")
                hosts=$(jq -r ".secrets[\"$key\"].hosts | if . == [] then \"(admin only)\" else join(\" \") end" <<<"$m")
                state=missing
                if [ -e "$file" ]; then
                  have=$(grep -o 'recipient: age1[a-z0-9]*' "$file" | cut -d' ' -f2 | sort)
                  if [ "$have" = "$want" ]; then state=ok; else state=rekey; fi
                fi
                printf '%-32s %-8s %-9s %s\n' "$key" "$state" "$([ -n "$gen" ] && echo generate || echo prompt)" "$hosts"
                if [ "$argc_dry_run" = 1 ] || [ "$state" = ok ]; then continue; fi

                if [ "$state" = rekey ]; then
                  ${pkgs.sops}/bin/sops updatekeys -y "$file"
                  continue
                fi
                if [ -n "$gen" ]; then
                  value=$(bash -c "$gen")
                else
                  read -rsp "  enter $key: " value; echo
                fi
                jq -n --arg k "$key" --arg v "$value" '{($k): $v}' \
                  | ${pkgs.sops}/bin/sops --input-type json --output-type yaml \
                      --filename-override "$file" -e /dev/stdin > "$file"
              done
              [ "$argc_dry_run" = 1 ] || git add .sops.yaml ./*.yaml
            }

            eval "$(${pkgs.argc}/bin/argc --argc-eval "$0" "$@")"
          '')
        ];
      };
    };
}
