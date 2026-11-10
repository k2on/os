# The things the automations refer to, named once. Remotes by their ZHA
# device id (a device trigger needs it; the registry, .storage/
# core.device_registry, has their names); lights and speakers by entity.
{
  # Tuya TS0044, four buttons: 1 top left, 2 top right, 3 bottom left,
  # 4 bottom right.
  remotes = {
    livingRoom = "f73b40a8ff83de335d0ac884a2c8980a"; # "Button"
    leftPanel = "17fecbf4087dcfa2f9ee79b2bd0113ed"; # "Max Pannel" in Home Assistant
    rightPanel = "dc4e48aafa835ec3f94a738ed0306a61"; # "Heather Pannel" in Home Assistant
  };

  # Each room's lamps one by one, as Adaptive Lighting adapts them (not the
  # rooms' Hue groups: see ../default.nix).
  lamps = {
    livingRoom = [
      "light.fan_1" # Left
      "light.fan_3" # Right
      "light.stairs" # Lamp
    ];
    left = "light.fan_2";
    right = "light.bathroom_1";
    mirror = "light.kitchen";
  };

  # The rooms' Hue groups.
  groups = {
    livingRoom = "light.living_room";
    bedroom = "light.bedroom_2";
  };

  adaptiveLighting = {
    livingRoom = "switch.adaptive_lighting_living_room";
    bedroom = "switch.adaptive_lighting_bedroom";
  };

  speakers = {
    livingRoom = "media_player.living_room";
    bedroom = "media_player.bedroom";
  };
}
