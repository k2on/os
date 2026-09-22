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

            sops=${pkgs.sops}/bin/sops

            manifest() {
              nix eval --json '.?submodules=1#arkSecrets'
            }

            # Run a command with the provider tokens in its environment. They
            # all live in one file (lib/secrets.nix), so this is one decryption
            # and one yubikey touch. Refuses to start if any token is missing;
            # the key names are plaintext in a sops file, so that needs no touch.
            with_infra() {
              missing=$(
                for key in $(manifest | jq -r '.secrets | to_entries[] | select(.value.file == "infra") | .key'); do
                  grep -q "^$key:" secrets/vars/infra.yaml 2>/dev/null || echo "$key"
                done
              )
              if [ -n "$missing" ]; then
                echo "ark: infra secrets missing from secrets/vars/infra.yaml:" $missing >&2
                echo "ark: run \`ark secrets\` to enter them" >&2
                return 1
              fi
              $sops exec-env secrets/vars/infra.yaml "$1"
            }

            # @cmd Plan out internet infra
            plan() {
              with_infra 'nix run ".?submodules=1#infra.plan"'
            }

            # @cmd Generate internet infra
            push () {
              # terranix's generated apply script ends in a bare `tofu apply` and
              # never forwards "$@", so `-- -auto-approve` was silently dropped.
              # Answer the approval prompt on stdin instead.
              with_infra 'nix run ".?submodules=1#infra.apply"'
            }

            # @cmd Destroy internet infra
            destroy () {
              with_infra 'nix run ".?submodules=1#infra.destroy"'
            }

            # @cmd List every secret declared in nix; create the missing ones, rekey the changed ones
            # See modules/ark/lib/secrets.nix for the `secrets` quirk this reads.
            # Creating never decrypts. Rekeying, or adding a key to a file that
            # already exists, decrypts that file once.
            # @flag -n --dry-run  Only list what is missing or stale, change nothing
            secrets() {
              m=$(manifest)
              mkdir -p secrets/vars && cd secrets/vars
              # sops finds this .sops.yaml on its own from inside secrets/vars,
              # so `sops <file>.yaml` works here by hand as well.
              [ "$argc_dry_run" = 1 ] || jq .sopsConfig <<<"$m" > .sops.yaml

              declare -A missing rekey
              printf '%-32s %-8s %-9s %s\n' SECRET STATE SOURCE HOSTS
              for key in $(jq -r '.secrets | keys[]' <<<"$m"); do
                file=$(jq -r ".secrets[\"$key\"].file" <<<"$m").yaml
                gen=$(jq -r ".secrets[\"$key\"].generate // empty" <<<"$m")
                hosts=$(jq -r ".secrets[\"$key\"].hosts | if . == [] then \"(admin only)\" else join(\" \") end" <<<"$m")
                state=missing
                if [ -e "$file" ] && grep -q "^$key:" "$file"; then
                  have=$(grep -o 'recipient: age1[a-z0-9]*' "$file" | cut -d' ' -f2 | sort)
                  want=$(jq -r ".secrets[\"$key\"].recipients[]" <<<"$m" | sort)
                  if [ "$have" = "$want" ]; then state=ok; else state=rekey; fi
                fi
                printf '%-32s %-8s %-9s %s\n' "$key" "$state" "$([ -n "$gen" ] && echo generate || echo prompt)" "$hosts"
                case $state in
                  missing) missing[$file]+="$key " ;;
                  rekey) rekey[$file]=1 ;;
                esac
              done
              [ "$argc_dry_run" = 1 ] && return

              for file in "''${!rekey[@]}"; do
                $sops updatekeys -y "$file"
              done

              for file in $(printf '%s\n' "''${!missing[@]}" | sort); do
                new=$(
                  for key in ''${missing[$file]}; do
                    gen=$(jq -r ".secrets[\"$key\"].generate // empty" <<<"$m")
                    if [ -n "$gen" ]; then
                      value=$(bash -c "$gen")
                    else
                      read -rsp "  enter $key: " value; echo >&2
                    fi
                    jq -n --arg k "$key" --arg v "$value" '{($k): $v}'
                  done | jq -s add
                )
                if [ -e "$file" ]; then
                  # merge into what is already there: one decryption
                  new=$(jq -s add <($sops -d --output-type json "$file") <(echo "$new"))
                fi
                echo "$new" | $sops --input-type json --output-type yaml \
                  --filename-override "$file" -e /dev/stdin > "$file.tmp" && mv "$file.tmp" "$file"
              done
              git add .sops.yaml ./*.yaml
            }

            eval "$(${pkgs.argc}/bin/argc --argc-eval "$0" "$@")"
          '')
        ];
      };
    };
}
