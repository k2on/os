# What the household's Apple devices are set to (ark.devices.apple, from
# ./default.nix), every device alike. Declarations' schemas:
# github.com/apple/device-management, declarative/declarations; profile
# payloads': mdm/profiles there.
{ ... }:
{
  ark.devices.apple.profiles.restrictions = [
    {
      PayloadType = "com.apple.applicationaccess";
      PayloadDisplayName = "Restrictions";
      # Apple's own apps that can't be deleted are hidden instead
      # (supervised only): gone from the home screen and App Library.
      blockedAppBundleIDs = [
        "com.apple.tips"
      ];
    }
  ];
}
