{ ... }: {
  programs.zathura = {
    enable = true;
    options = {
      default-bg = "white";
      font = "Monocraft";
      selection-clipboard = "clipboard";
    };
  };
}
