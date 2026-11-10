# The whole apartment: every light off from either bedroom panel (held),
# and lights and music off when the last person leaves.
{ d, l }:
[
  {
    id = "1780291199212";
    alias = "Lights off";
    description = "Either bedroom panel's toggle, held";
    triggers = [
      (l.hold d.remotes.leftPanel (l.layout false).toggle)
      (l.hold d.remotes.rightPanel (l.layout true).toggle)
    ];
    actions = [
      {
        action = "light.turn_off";
        target.area_id = [
          "bedroom"
          "living_room"
        ];
      }
    ];
    mode = "single";
  }
  {
    id = "1780336506285";
    alias = "No One Home";
    description = "A minute after the last person leaves";
    triggers = [
      {
        trigger = "state";
        entity_id = [ "zone.home" ];
        to = "0";
        for.minutes = 1;
      }
    ];
    actions = [
      {
        action = "media_player.media_pause";
        target.entity_id = [
          d.speakers.bedroom
          d.speakers.livingRoom
        ];
      }
      {
        action = "light.turn_off";
        target.entity_id = [
          d.groups.bedroom
          d.groups.livingRoom
        ];
      }
    ];
    mode = "single";
  }
]
