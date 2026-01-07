{ pkgs, proton-pass-cli, config, ... }:
let
  cache-path = "$HOME/.cache/pass";

  proton-pass = pkgs.writeShellScriptBin "pass-cli" ''
    export PROTON_PASS_KEY_PROVIDER="env"
    export PROTON_PASS_ENCRYPTION_KEY="${config.sops.secrets.proton_key.path}"
    exec ${proton-pass-cli.packages.${pkgs.system}.default}/bin/pass-cli "$@"
  '';

  pass-sync = pkgs.writeShellScriptBin "pass-sync" ''
    mkdir -p "${cache-path}"
    vaults=$(${proton-pass}/bin/pass-cli vault list --output json | ${pkgs.jq}/bin/jq '.vaults[].name' -r)
    for vault in $vaults; do
      ${proton-pass}/bin/pass-cli item list $vault --filter-state active --output json | ${pkgs.jq}/bin/jq '.items[].content.title' -r > "${cache-path}/$vault"
    done
  '';

  pass-fzf = pkgs.writeShellScriptBin "pass-fzf" ''
    selected=$(for f in ~/.cache/pass/*; do while IFS= read -r line; do echo "$(basename "$f"): $line"; done < "$f"; done | fzf)
    vault=$(echo "$selected" | cut -d':' -f1)
    item=$(echo "$selected" | cut -d':' -f2- | sed 's/^ //')
    ${proton-pass}/bin/pass-cli item view --vault-name "$vault" --item-title "$item" --output json | ${pkgs.jq}/bin/jq '.item.content.content.Login.password' | ${pkgs.wl-clipboard}/bin/wl-copy
  '';

in {
  environment.systemPackages = [
    proton-pass
    pass-sync
    pass-fzf
  ];
}
