{ ... }: {
  flake.homeModules.commonFeatureAlacritty = { ... }: {
    programs.alacritty = {
      enable = true;
      theme = "tokyo_night";
      settings = {
        window = {
          padding = { x = 14; y = 14; };
        };
        font = {
          normal.family = "JetBrainsMono Nerd Font";
          size = 10;
        };
        keyboard.bindings = [
          { key = "Insert"; mods = "Shift"; action = "Paste"; }
          { key = "Insert"; mods = "Control"; action = "Copy"; }
        ];
      };
    };
  };
}
