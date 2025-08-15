{ pkgs, ... }: {
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" "zh_CN.UTF-8/UTF-8" ];
  i18n.inputMethod = {
    enabled = "fcitx5";
    fcitx5.addons = with pkgs; [
      # fcitx5-gtk             # alternatively, kdePackages.fcitx5-qt
      kdePackages.fcitx5-qt # alternatively, kdePackages.fcitx5-qt
      fcitx5-chinese-addons # table input method support
      fcitx5-nord # a color theme
    ];
  };

}
