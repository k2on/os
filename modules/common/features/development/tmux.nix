{ ... }: {
  flake.homeModules.commonFeatureTmux = { pkgs, ... }: {
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
  };
}
