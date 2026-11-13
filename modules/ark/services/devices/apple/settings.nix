# What the household's Apple devices are set to (ark.devices.apple, from
# ./default.nix), every device alike. Declarations' schemas:
# github.com/apple/device-management, declarative/declarations; profile
# payloads': mdm/profiles there.
{ ... }:
{
  # Apps' notifications, enforced: they can't be changed on the device. One
  # payload of this type per device, so every app's go in this one list.
  ark.devices.apple.profiles.notifications = [
    {
      PayloadType = "com.apple.notificationsettings";
      PayloadDisplayName = "Notifications";
      NotificationSettings = [
        {
          BundleIdentifier = "com.apple.mobilemail";
          NotificationsEnabled = true;
          ShowInNotificationCenter = true;
          ShowInLockScreen = true;
          # 1: banners that go away by themselves.
          AlertType = 1;
          BadgesEnabled = true;
          SoundsEnabled = true;
        }
      ];
    }
  ];

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
