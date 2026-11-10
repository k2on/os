# Home Assistant's automations, one file per part of the apartment, made
# into the YAML files its `automation: !include_dir_merge_list automations`
# reads (../default.nix). JSON is YAML, so each is written as JSON.
#
# Each keeps the id it had when it was made in the UI, so its entity
# (automation.<alias>) and history stay. The UI shows them read-only: they
# change here.
{ pkgs, lib }:
let
  d = import ./devices.nix;
  l =
    let
      base = import ./lib.nix { inherit lib; };
    in
    base // { panel = import ./panel.nix { l = base; }; };
  files = {
    living-room = import ./living-room.nix { inherit d l; };
    bedroom = import ./bedroom.nix { inherit d l; };
    house = import ./house.nix { inherit d l; };
  };
in
pkgs.runCommand "home-assistant-automations" { } ''
  mkdir $out
  ${lib.concatStrings (
    lib.mapAttrsToList (name: automations: ''
      cp ${pkgs.writeText "${name}.yaml" (builtins.toJSON automations)} $out/${name}.yaml
    '') files
  )}
''
