# What the household's Apple devices are set to (ark.devices.apple, from
# ./default.nix), every device alike. Declarations' schemas:
# github.com/apple/device-management, declarative/declarations; profile
# payloads': mdm/profiles there.
{ config, ... }:
let
  ark = config.ark;
in
{
  # More apps, licensed in Apple Business (Apps and Books) like Tailscale
  # (./default.nix). App Store IDs: the number in an app's apps.apple.com
  # URL, or itunes.apple.com/lookup?id=<id>.
  ark.devices.apple.apps = {
    # Opens already pointed at the vault (services/pass); signing in is
    # still yours. bitwarden.com/help/deploy-clients
    bitwarden = {
      storeId = "1137397744";
      config.baseEnvironmentUrl = "https://${ark.serviceDomain "pass" ark.services.pass}";
    };
    # None of these take settings from MDM. Nextcloud's code reads a server
    # from it, but only in rebranded builds (use_AppConfig, Brand/NCBrand.swift
    # in nextcloud/ios), not the App Store's: its server is chosen in the app.
    home-assistant.storeId = "1099568401";
    immich.storeId = "1613945652";
    nextcloud.storeId = "1125420102";
    signal.storeId = "874139669";
    privacy.storeId = "1040298266"; # Privacy.com
    google-maps.storeId = "585027354";
    bible.storeId = "282935706"; # YouVersion, Life.Church
    # For betas, installed by hand from it: those aren't managed.
    testflight.storeId = "899247664";
  };

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

  # Black, Lock Screen and Home Screen, kept by the restriction below.
  ark.devices.apple.wallpaper.color = "black";

  ark.devices.apple.profiles.restrictions = [
    {
      PayloadType = "com.apple.applicationaccess";
      PayloadDisplayName = "Restrictions";
      # The wallpaper stays what's set above.
      allowWallpaperModification = false;
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
        # Apple TV Remote: the app only; the Control Center button stays.
        "com.apple.TVRemote"
      ];
    }
  ];
}
