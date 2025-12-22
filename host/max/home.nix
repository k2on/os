{ ... }:

{
  imports = [
    ./home/sops.nix
    ./home/ssh.nix
    ./home/git.nix

    ./home/browser.nix

    ../../home/common/optional/desktop/hyprland.nix

    ./home/nvim.nix
    ./home/terminal.nix
    ./home/zathura.nix
  ];

  home.username = "max";
  home.homeDirectory = "/home/max";
  home.stateVersion = "25.05";
}
