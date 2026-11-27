# Max's programs: what was cale's system packages, now his home's, so they
# come with him (his home) rather than with the machine. What
# is the machine's (its battery, the network, a disk tool, an editor for
# root) stays in ./configuration.nix.
{ self, config, ... }:
let
  domain = config.ark.mainDomain;
in
{
  den.aspects.max.homeManager =
    { pkgs, ... }:
    let
      apps = self.inputs.koon-apps.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      home.packages = with pkgs; [
        just

        libreoffice-qt

        pkgs-unstable.signal-desktop
        pkgs-unstable.gurk-rs

        (pass.withExtensions (exts: [ exts.pass-otp ]))

        fzf
        zip
        jq
        ffmpeg
        ripgrep
        unzip
        zbar
        tt
        sc-im
        libqalculate
        librespeed-cli
        tree

        wl-clipboard

        tea
        gh

        glow
        delta

        cloudflared

        pkgs-unstable.claude-code

        (chromium.override { enableWideVine = true; })

        gimp
        inkscape

        # arm support
        pkgs-unstable.sparrow

        android-tools

        (writeShellScriptBin "radio" ''
          list="
          WIOP http://s4.yesstreaming.net:7119/;audio.mp3
          FamilyAlter https://usa17.fastcast4u.com/proxy/roloffev?mp=/1
          "

          choice=$(echo "$list" | awk '{print $1}' | ${fzf}/bin/fzf)

          if [[ -n "$choice" ]]; then
            url=$(echo "$list" | awk -v name="$choice" '$1==name {print $2}')
            ${mpg123}/bin/mpg123 "$url"
          fi
        '')

        (writeShellScriptBin "ocr-clip" ''
          ${grimblast}/bin/grimblast -f save area - | ${tesseract}/bin/tesseract stdin stdout | ${wl-clipboard}/bin/wl-copy
        '')

        # harken's and money's desktop apps (koon-apps' iced clients), each
        # on ark's server.
        (writeShellScriptBin "harken" ''
          exec ${apps.harken-iced}/bin/harken-iced --server https://harken.${domain} "$@"
        '')
        (makeDesktopItem {
          name = "harken";
          desktopName = "Harken";
          exec = "harken";
          categories = [
            "AudioVideo"
            "Audio"
          ];
        })

        (writeShellScriptBin "money" ''
          exec ${apps.money-iced}/bin/money-iced --server https://money.${domain} "$@"
        '')
        (makeDesktopItem {
          name = "money";
          desktopName = "Money";
          exec = "money";
          categories = [
            "Office"
            "Finance"
          ];
        })
      ];
    };
}
