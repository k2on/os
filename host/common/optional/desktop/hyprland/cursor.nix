{ pkgs, lib, ... }:
{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "apple_cursor"
  ];

  environment.systemPackages = with pkgs; [
    apple-cursor
  ];
}
