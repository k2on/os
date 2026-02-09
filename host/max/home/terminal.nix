{ pkgs, config, ... }: {
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

  programs.lf = { enable = true; };

  programs.tmux = {
    enable = true;
    mouse = true;
    keyMode = "vi";
    shell = "${pkgs.zsh}/bin/zsh";
    extraConfig = ''
      set -g status-style bg=default

      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R

      set -g default-terminal "tmux-256color"
      set -ga terminal-overrides ",alacritty:Tc"
    '';
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion = {
      enable = true;
    };
    syntaxHighlighting.enable = true;
    dotDir = "${config.home.homeDirectory}/.config/zsh";
    autocd = true;

    initContent = ''
      zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
      zstyle ':completion:*' menu select

      fzf-project() {
        selected=$(find ~/dev -mindepth 2 -maxdepth 2 | sed 's|/home/max/dev/||' | fzf --delimiter '/' --nth 2)
        if [[ -n $selected ]]; then
          cd ~/dev/$selected
          zle reset-prompt
        fi
        zle redisplay
      }

      zle -N fzf-project
      bindkey '^G' fzf-project

      fzf-files() {
        local selected
        selected=$(${pkgs.ripgrep}/bin/rg --files | ${pkgs.fzf}/bin/fzf) || return

        if [[ -n $selected ]]; then
          BUFFER="v $selected"
          print -s -- "$BUFFER"
          zle accept-line
        fi
      }

      zle -N fzf-files
      bindkey '^V' fzf-files

      open() {
        xdg-open "$@" >/dev/null 2>&1 &
      }
    '';

    envExtra = ''
      export PER_DIRECTORY_HISTORY_TOGGLE="^H"
      export HISTORY_BASE="$HOME/.local/share/directory_history"
    '';

    shellAliases = {
      ll = "ls -alh";
      v = "nvim";
      vi = "nvim";
      vim = "nvim";

      p = "pnpm";
      g = "pnpm run build && ~/dev/personal/genesis/packages/genesis/dist/bin.js";

      ns = "nix-shell --run zsh -p";

      tt = "tt -notheme -n 10";

      bible = "nvim ~/bible.txt -R";
      notes = "nvim ~/notes";
      home = "sudo nvim /etc/nixos/home.nix";
      wttr = "curl wttr.in/Clemson";

      docx-to-pdf = "libreoffice --headless --convert-to pdf";
    };

    plugins = [
      {
        name = "vi-mode";
        src = pkgs.zsh-vi-mode;
        file = "share/zsh-vi-mode/zsh-vi-mode.plugin.zsh";
      }
      {
        name = "per-directory-history";
        src = pkgs.fetchFromGitHub {
          owner = "jimhester";
          repo = "per-directory-history";
          rev = "95f06973e9f2ff0ff75f3cebd0a2ee5485e27834";
          sha256 = "sha256-EV9QPBndwAWzdOcghDXrIIgP0oagVMOTyXzoyt8tXRo=";
        };
      }
    ];
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
    silent = true;
  };

  programs.starship = { enable = true; };
}
