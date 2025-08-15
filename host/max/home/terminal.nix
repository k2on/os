{ pkgs, ... }: {
  programs.alacritty = {
    enable = true;
    theme = "one_light";
    settings = {
      font = {
        normal.family = "Monocraft";
        size = 10;
      };
    };
  };

  programs.lf = { enable = true; };

  programs.tmux = {
    enable = true;
    mouse = true;
    keyMode = "vi";
    shell = "${pkgs.zsh}/bin/zsh";
    extraConfig = ''
      set -g status-style bg=white

      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R
    '';
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion = {
      enable = true;
      highlight = "fg=#bbbbbb";
    };
    syntaxHighlighting.enable = true;
    dotDir = ".config/zsh";
    autocd = true;

    # initExtra = builtins.readFile ./zsh-nix-shell.zsh;

    shellAliases = {
      ll = "ls -la --color";
      v = "nvim";
      vi = "nvim";
      vim = "nvim";

      k = "kubectl";

      tt = "tt --theme one-light -n 10";

      bible = "nvim ~/bible.txt -R";
      notes = "nvim ~/notes";
      home = "sudo nvim /etc/nixos/home.nix";
      wttr = "curl wttr.in/Clemson";

      docx-to-pdf = "libreoffice --headless --convert-to pdf";
    };

    plugins = [{
      name = "vi-mode";
      src = pkgs.zsh-vi-mode;
      file = "share/zsh-vi-mode/zsh-vi-mode.plugin.zsh";
    }];
  };

  programs.starship = { enable = true; };
}
