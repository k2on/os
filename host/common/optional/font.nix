{ pkgs, apple-fonts, ... }: {
  fonts = {
    fontconfig.defaultFonts = {
      sansSerif = [ "SF Pro" ];
      serif = [ "SF Pro" ];
      monospace = [ "JetBrainsMono Nerd Font" ];
      emoji = [ "Apple Color Emoji" ];
    };

    packages = with pkgs; [
      monocraft
      noto-fonts-cjk-sans
      nerd-fonts.jetbrains-mono
      (apple-fonts.packages.${pkgs.system}.sf-pro)
      (stdenv.mkDerivation {
        name = "apple-color-emoji";
        src = fetchurl {
          url =
            "https://github.com/samuelngs/apple-emoji-linux/releases/download/v17.4/AppleColorEmoji.ttf";
          sha256 = "1wahjmbfm1xgm58madvl21451a04gxham5vz67gqz1cvpi0cjva8";
        };
        dontUnpack = true;
        installPhase = ''
          install -Dm644 $src $out/share/fonts/truetype/AppleColorEmoji.ttf
        '';
      })
    ];
  };
}
