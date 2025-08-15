{ pkgs, ... }: {
  fonts.packages = with pkgs; [
    monocraft

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
}
