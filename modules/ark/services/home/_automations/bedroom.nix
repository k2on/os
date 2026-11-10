# The bedroom: the left panel and the right one, each its side's lamp
# (panel.nix; the right one flipped), and the morning alarm.
{ d, l }:
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
    description = "At the alarm's time (input_datetime.alarm): the bedroom's lights up over five minutes, and calm radio";
    triggers = [
      {
        trigger = "time";
        at = "input_datetime.alarm";
      }
    ];
    actions = [
      {
        action = "light.turn_on";
        target.area_id = "bedroom";
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
          # Calm Radio - Solo Piano & Guitar, through Radio Browser.
          media_content_id = "media-source://radio_browser/cd150a3d-7ffc-4747-827b-158358d41ebe";
          media_content_type = "audio/mpeg";
        };
      }
    ];
    mode = "single";
  }
]
