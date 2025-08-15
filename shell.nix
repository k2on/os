{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = [
    pkgs.age
    pkgs.ssh-to-age
    pkgs.sops
    pkgs.just
 ];
}
