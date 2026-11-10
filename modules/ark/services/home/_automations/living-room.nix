# The living room's button (remotes.livingRoom), a panel like the left one in
# the bedroom (panel.nix): the room's lights, and the music on the spare button.
{ d, l }:
l.panel {
  remote = d.remotes.livingRoom;
  toggle = {
    id = "1780254699902";
    alias = "Toggle Lights";
    target.area_id = "living_room";
  };
  brightness = {
    id = "1793318400003";
    alias = "Living Room Brightness";
    lamps = d.lamps.livingRoom;
    adaptiveLighting = d.adaptiveLighting.livingRoom;
  };
  spare = {
    id = "1780254931068";
    alias = "Play Pause";
    actions = [
      {
        action = "media_player.media_play_pause";
        target.area_id = "living_room";
      }
    ];
  };
}
