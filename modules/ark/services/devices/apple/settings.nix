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
      # IDs: support.apple.com/guide/deployment/depece748c41 (case matters).
      blockedAppBundleIDs = [
        "com.apple.tips" # Tips
        "com.apple.tv" # TV
        "com.apple.games" # Games
        "com.apple.MobileStore" # iTunes Store
        "com.apple.podcasts" # Podcasts
        "com.apple.Home" # Home
        "com.apple.iBooks" # Books
        "com.apple.Fitness" # Fitness
        "com.apple.Bridge" # Watch
        "com.apple.journal" # Journal
        "com.apple.GenerativePlaygroundApp" # Image Playground
        "com.apple.Health" # Health
        "com.apple.Music" # Music
        "com.apple.news" # News
      ];
    }
  ];
}
