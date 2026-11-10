# One panel's automations, all laid out alike (lib.nix `layout`): the toggle
# switches `toggle.target`, brighter and dimmer step `brightness.lamps`, and
# the spare button, when given, does `spare.actions`. Each automation keeps
# the id and alias it was made with in the UI.
{ l }:
{
  remote,
  flipped ? false,
  toggle,
  brightness,
  spare ? null,
}:
let
  b = l.layout flipped;
in
[
  {
    inherit (toggle) id alias;
    triggers = [ (l.press remote b.toggle) ];
    actions = [
      {
        action = "light.toggle";
        inherit (toggle) target;
      }
    ];
    mode = "single";
  }
  {
    inherit (brightness) id alias;
    description = "Opposite the toggle: button ${toString b.up} brighter, button ${toString b.down} dimmer, a quarter of full brightness a press";
    triggers = [
      (l.press remote b.up // { id = "up"; })
      (l.press remote b.down // { id = "down"; })
    ];
    actions = l.brightness { inherit (brightness) lamps adaptiveLighting; };
    mode = "queued";
  }
]
++ (
  if spare == null then
    [ ]
  else
    [
      {
        inherit (spare) id alias actions;
        triggers = [ (l.press remote b.spare) ];
        mode = "single";
      }
    ]
)
