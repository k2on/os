# Pieces the automations share.
{ lib }:
{
  # A short, double or long press of a remote's button.
  press = remote: button: {
    device_id = remote;
    domain = "zha";
    type = "remote_button_short_press";
    subtype = "button_${toString button}";
    trigger = "device";
  };
  double = remote: button: {
    device_id = remote;
    domain = "zha";
    type = "remote_button_double_press";
    subtype = "button_${toString button}";
    trigger = "device";
  };
  hold = remote: button: {
    device_id = remote;
    domain = "zha";
    type = "remote_button_long_press";
    subtype = "button_${toString button}";
    trigger = "device";
  };

  # Brighter or dimmer by a quarter a press, on `up` and `down` presses (the
  # triggers' ids), and straight to full or the lowest on `max` and `min`
  # (double presses): the lamps that are on, or all of them when none is. Then
  # Adaptive Lighting leaves them be until they are next turned off, so it
  # does not undo the change.
  brightness =
    {
      lamps,
      adaptiveLighting,
    }:
    let
      targets = "{% set lamps = ${builtins.toJSON lamps} %}{{ (lamps | select('is_state', 'on') | list) or lamps }}";
    in
    [
      { variables.targets = targets; }
      {
        "if" = [
          {
            condition = "template";
            value_template = "{{ trigger.id in ['max', 'min'] }}";
          }
        ];
        "then" = [
          {
            action = "light.turn_on";
            target.entity_id = "{{ targets }}";
            data.brightness_pct = "{{ 100 if trigger.id == 'max' else 1 }}";
          }
        ];
        "else" = [
          {
            action = "light.turn_on";
            target.entity_id = "{{ targets }}";
            data.brightness_step_pct = "{{ 25 if trigger.id == 'up' else -25 }}";
          }
        ];
      }
      {
        action = "adaptive_lighting.set_manual_control";
        data = {
          entity_id = adaptiveLighting;
          lights = "{{ targets }}";
          manual_control = true;
        };
      }
    ];

  # The panels' layout, Tuya TS0044 (1 top left, 2 top right, 3 bottom left,
  # 4 bottom right): the toggle top left, brighter and dimmer down the right,
  # one spare bottom left; flipped (the right side of the bed's), left and
  # right swapped.
  layout =
    flipped:
    if flipped then
      {
        toggle = 2;
        up = 1;
        down = 3;
        spare = 4;
      }
    else
      {
        toggle = 1;
        up = 2;
        down = 4;
        spare = 3;
      };
}
