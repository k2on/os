# The bedroom: the left panel and the right one, each its side's lamp
# (panel.nix; the right one flipped), and the morning alarm.
{ d, l }:
let
  wakeLamps = [
    d.lamps.left
    d.lamps.right
  ];
in
l.panel {
  remote = d.remotes.leftPanel;
  toggle = {
    id = "1780284452314";
    alias = "Left Lamp";
    target.entity_id = d.lamps.left;
  };
  brightness = {
    id = "1793318400001";
    alias = "Left Lamp Brightness";
    lamps = [ d.lamps.left ];
    adaptiveLighting = d.adaptiveLighting.bedroom;
  };
}
++ l.panel {
  remote = d.remotes.rightPanel;
  flipped = true;
  toggle = {
    id = "1784591298718";
    alias = "Right Lamp";
    target.entity_id = d.lamps.right;
  };
  brightness = {
    id = "1793318400002";
    alias = "Right Lamp Brightness";
    lamps = [ d.lamps.right ];
    adaptiveLighting = d.adaptiveLighting.bedroom;
  };
}
++ [
  {
    id = "1780285441878";
    alias = "Wake Up";
    description = "At the alarm's time (input_datetime.alarm): the bedroom's lamps up over five minutes, and calm radio";
    triggers = [
      {
        trigger = "time";
        at = "input_datetime.alarm";
      }
    ];
    actions = [
      # The alarm's own brightness and colour, not Adaptive Lighting's: the
      # lamps under manual control first, so it leaves the call alone (as
      # it rewrote it, it failed). Adaptive again once they're turned off.
      {
        action = "adaptive_lighting.set_manual_control";
        data = {
          entity_id = d.adaptiveLighting.bedroom;
          lights = wakeLamps;
          manual_control = true;
        };
      }
      {
        action = "light.turn_on";
        target.entity_id = wakeLamps;
        data = {
          brightness_pct = 100;
          color_temp_kelvin = 2577;
          transition = 300;
        };
      }
      {
        action = "media_player.volume_set";
        target.entity_id = d.speakers.bedroom;
        data.volume_level = 0.35;
      }
      {
        action = "media_player.play_media";
        target.entity_id = d.speakers.bedroom;
        data = {
          # Calm Radio - Solo Piano, through Radio Browser.
          media_content_id = "media-source://radio_browser/963b8a47-0601-11e8-ae97-52543be04c81";
          media_content_type = "audio/mpeg";
        };
      }
    ];
    mode = "single";
  }
]
