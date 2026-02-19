{
  services.swaync = {
    enable = true;

    settings = {
      notification-window-width = 350;
    };

    # Taken from: 
    # https://github.com/ErikReider/SwayNotificationCenter/blob/2083415ee6441acc272f46f8a43ebccae215f69a/data/style/style.scss#L4
    style = ''
      :root {
        --cc-bg: rgba(46, 46, 46, 0.7);

        --noti-border-color: rgba(255, 255, 255, 0.15);
        --noti-bg: 48, 48, 48;
        --noti-bg-alpha: 1;

        --border-radius: 0;

        --font-size-body: 13px;
        --font-size-summary: 14px;
      }

      .close-button {
        min-width: 18px;
        min-height: 18px;
      }
    '';
  };
}
