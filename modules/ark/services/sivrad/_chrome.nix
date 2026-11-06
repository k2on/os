# A real, headed browser for sivrad: ungoogled-chromium on a virtual
# screen, which the agent drives over the Chrome DevTools Protocol (its
# browser tools through Playwright, ./_browser.nix and ./_codex.nix), and
# which a person can watch and take over (sign in, solve a CAPTCHA) from a
# web page: noVNC, at https://sivrad.<mainDomain>/browser behind a Kanidm
# sign-in.
#   imports = [ (import ./_chrome.nix { ... }) ];
#
# The pieces, each a systemd service in the guest:
#   - sivrad-display: Xvfb, a virtual X screen (:1); sivrad-wm on it:
#     matchbox, a window manager that keeps one window full-screen with no
#     decorations, as a kiosk does;
#   - sivrad-chromium: the browser on that screen, with its profile (the
#     sign-ins) under its own home, and DevTools on loopback;
#   - sivrad-vnc: x11vnc, which shares the screen on localhost:5900, with no
#     password of its own;
#   - sivrad-novnc: websockify serving noVNC, the VNC client as a web page,
#     on novncPort, which the guest's firewall opens to adam alone, on the
#     veth;
#   - sivrad-cdp-relay: socat, DevTools relayed on cdpRelayPort for money's
#     server on adam, opened to adam alone the same way.
# On adam, the sivrad-browser service (./default.nix) serves that page at
# https://sivrad.<mainDomain>/browser: nginx with the wildcard's
# certificate, then oauth2-proxy, which lets through only those who sign in
# with Kanidm and are in its group (browserPeople, ./default.nix), websockets included.
# That sign-in is the page's only lock, so nothing inside the container may
# reach x11vnc or the page either; see the firewall at the bottom.
#
# Who runs what: the screen and the browser run as `browserUser`, not as
# the agent, so the profile (cookies: people's sessions) and the X socket
# (the screen, and typing into it) are out of the agent's reach by
# permission; it acts on the browser through DevTools, which is what its
# browser tools do, and only its account may connect to that port. x11vnc
# runs as `sivrad-vnc`; the two share the X socket directory through the
# `sivrad-screen` group. Downloads go to the agent's workspace,
# group-writable, so it can read and send them.
{
  browserUser,
  # The browser's home, with its profile under it, kept between restarts.
  browserHome,
  # Where the old setup kept the profile (under the agent's home); moved
  # here on the first start, so sign-ins survive the change of owner.
  legacyProfile,
  # The agent's workspace, for downloads.
  workspace,
  # The X display the browser runs on, the DevTools port, the noVNC page's
  # port and path, and the only address it answers: adam's end of the veth.
  display,
  cdpPort,
  novncPort,
  novncPrefix,
  hostAddress,
  # DevTools relayed to adam's end of the veth, for money's server there.
  cdpRelayPort,
}:
{ lib, pkgs, ... }:
let
  profile = "${browserHome}/profile";
  downloads = "${workspace}/downloads";

  # Screen size: what the browser renders at, and what noVNC scales to the
  # viewer's window.
  width = 1440;
  height = 900;
  # Xvfb's socket; the services on the screen wait for it.
  displaySocket = "/tmp/.X11-unix/X${lib.removePrefix ":" display}";
  waitForDisplay = pkgs.writeShellScript "sivrad-wait-for-display" ''
    for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
      [ -S ${displaySocket} ] && exit 0
      ${pkgs.coreutils}/bin/sleep 1
    done
    echo "no X display at ${displaySocket}" >&2
    exit 1
  '';

  # Fonts for real pages: fontconfig is off in the guest; Liberation stands
  # in for Arial, Times and Courier.
  fonts = pkgs.makeFontsConf {
    fontDirectories = [
      pkgs.dejavu_fonts
      pkgs.liberation_ttf
    ];
  };

  # noVNC's page under novncPrefix (/browser), as people reach it at
  # https://sivrad.<mainDomain>/browser/: oauth2-proxy passes the path on
  # unchanged, so websockify serves the files from that directory. Its
  # index opens the client connected and scaled to the window, with the
  # WebSocket at <prefix>/websockify (noVNC's `path`, relative to the
  # host): wss:// on the same host, through the same proxy and sign-in.
  # websockify takes the WebSocket on any path.
  novncWeb = pkgs.runCommand "sivrad-novnc-web" { } ''
    mkdir -p $out${novncPrefix}
    ln -s ${pkgs.novnc}/share/webapps/novnc/* $out${novncPrefix}/
    cat > $out${novncPrefix}/index.html <<'EOF'
    <!doctype html>
    <meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=scale&reconnect=true&path=${lib.removePrefix "/" novncPrefix}/websockify">
    EOF
  '';

  # The profile from before the browser had an account of its own, moved
  # into place once; root does it (ExecStartPre with `+`), as the old
  # files are the agent's.
  migrateProfile = pkgs.writeShellScript "sivrad-migrate-profile" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    if [ -d ${legacyProfile} ] && [ ! -d ${profile} ]; then
      echo "moving the browser profile from ${legacyProfile} to ${profile}"
      mv ${legacyProfile} ${profile}
      chown -R ${browserUser}:${browserUser} ${profile}
      chmod 0700 ${profile}
    fi
  '';

  # What the services drawing on or reading the screen share: they start
  # with it, stop and restart with it, and wait for its socket. (BindsTo
  # stops them with the screen; being wanted by it starts them again when
  # it comes back.)
  onScreen = {
    wantedBy = [
      "multi-user.target"
      "sivrad-display.service"
    ];
    after = [ "sivrad-display.service" ];
    bindsTo = [ "sivrad-display.service" ];
    environment.DISPLAY = display;
    serviceConfig = {
      ExecStartPre = [ waitForDisplay ];
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true; # /home and /root; the homes are under /var/lib
      PrivateTmp = false; # the X socket is in /tmp
      UMask = "0077";
    };
  };
  asBrowser = lib.recursiveUpdate onScreen {
    environment.HOME = browserHome;
    serviceConfig = {
      User = browserUser;
      Group = browserUser;
    };
  };
in
{
  users.users.${browserUser} = {
    isSystemUser = true;
    group = browserUser;
    home = browserHome;
    # The screen's socket directory, and the agent's workspace for the
    # downloads.
    extraGroups = [
      "sivrad-screen"
      "sivrad"
    ];
  };
  users.groups.${browserUser} = { };
  users.groups.sivrad-screen = { };
  users.users.sivrad-vnc = {
    isSystemUser = true;
    group = "sivrad-vnc";
    extraGroups = [ "sivrad-screen" ];
  };
  users.groups.sivrad-vnc = { };
  users.users.sivrad-novnc = {
    isSystemUser = true;
    group = "sivrad-novnc";
  };
  users.groups.sivrad-novnc = { };
  users.users.sivrad-cdp-relay = {
    isSystemUser = true;
    group = "sivrad-cdp-relay";
  };
  users.groups.sivrad-cdp-relay = { };

  # The policies, in /etc/chromium/policies/managed. programs.chromium
  # installs no browser, it only writes these files.
  programs.chromium = {
    enable = true;
    extraOpts = {
      # No extensions at all.
      ExtensionSettings."*" = {
        installation_mode = "blocked";
        blocked_install_message = "This browser runs no extensions (modules/ark/services/sivrad/_chrome.nix).";
      };
      # Only the system-wide native messaging hosts, of which there are none.
      NativeMessagingUserLevelHosts = false;
      NativeMessagingBlocklist = [ "*" ];

      # No Google account, sync or metrics (ungoogled-chromium has none of
      # these anyway; the policies say so for the next browser too).
      BrowserSignin = 0;
      SyncDisabled = true;
      MetricsReportingEnabled = false;
      SearchSuggestEnabled = false;
      # Sign-ins stay as cookies in the profile; passwords someone types
      # while taking over are not saved, nor addresses or cards.
      PasswordManagerEnabled = false;
      # Continue where it left off: with this, Chromium also keeps session
      # cookies across restarts, which is most sites' sign-in (Expedia's
      # among them). Without it every container restart signed the browser
      # out of everything.
      RestoreOnStartup = 1;
      AutofillAddressEnabled = false;
      AutofillCreditCardEnabled = false;
      PaymentMethodQueryEnabled = false;
      # Nobody to answer a site asking for these.
      DefaultNotificationsSetting = 2;
      DefaultGeolocationSetting = 2;
      AudioCaptureAllowed = false;
      VideoCaptureAllowed = false;
      # Downloads go to the workspace, where the agent may read and send
      # them, without a dialog.
      DownloadDirectory = downloads;
      PromptForDownloadLocation = false;
      DefaultBrowserSettingEnabled = false;
      BackgroundModeEnabled = false;
      # No GPU in the container.
      HardwareAccelerationModeEnabled = false;
    };
  };

  systemd.tmpfiles.rules = [
    "d ${browserHome} 0700 ${browserUser} ${browserUser} -"
    # Group `sivrad` writes nothing here; the agent reads.
    "d ${downloads} 2770 ${browserUser} sivrad -"
    # Xvfb runs as the browser's user, so the directory for its socket must
    # already be there: writable for the group that shares the screen,
    # sticky as X expects, and closed to everyone else, the agent included.
    "d /tmp/.X11-unix 1770 root sivrad-screen -"
  ];

  # The virtual screen. Xvfb takes no clients over TCP and has no
  # authorization file: whoever reaches its socket controls the screen,
  # which the directory's permissions limit to the sivrad-screen group.
  systemd.services.sivrad-display = {
    description = "Virtual X screen ${display} for sivrad's browser";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = browserUser;
      Group = browserUser;
      # A lock left behind by a crash would keep Xvfb from starting.
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /tmp/.X${lib.removePrefix ":" display}-lock ${displaySocket}";
      ExecStart = "${pkgs.xvfb}/bin/Xvfb ${display} -screen 0 ${toString width}x${toString height}x24 -nolisten tcp";
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict"; # read-only /, /tmp included unless listed
      ReadWritePaths = [ "/tmp" ]; # its socket and lock
      ProtectHome = true;
      PrivateTmp = false;
    };
  };

  # matchbox keeps the browser's window full-screen and puts dialogs and
  # pop-ups on top of it; without a window manager nothing would place or
  # focus windows.
  systemd.services.sivrad-wm = lib.recursiveUpdate asBrowser {
    description = "Window manager on ${display}";
    serviceConfig.ExecStart = "${pkgs.matchbox}/bin/matchbox-window-manager -use_titlebar no";
  };

  systemd.services.sivrad-chromium = lib.recursiveUpdate asBrowser {
    description = "ungoogled-chromium on ${display}, with DevTools on loopback";
    after = [
      "sivrad-display.service"
      "sivrad-wm.service"
    ];
    environment.FONTCONFIG_FILE = "${fonts}";
    serviceConfig = {
      ExecStartPre = [
        "+${migrateProfile}"
        waitForDisplay
      ];
      # Chromium's own sandbox stays on: it builds it from user namespaces,
      # so this unit sets nothing that would forbid them.
      #   --remote-debugging-*: DevTools for the agent's browser tools, on
      #     loopback only; --remote-allow-origins names the loopback
      #     origins, for a client that sends an Origin header (the
      #     firewall below says who may connect at all).
      #   --password-store=basic: no keyring in the container. The cookies
      #     are protected by the profile's permissions, not by a secret.
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.ungoogled-chromium}/bin/chromium"
        "--user-data-dir=${profile}"
        "--remote-debugging-address=127.0.0.1"
        "--remote-debugging-port=${toString cdpPort}"
        "--remote-allow-origins=http://127.0.0.1:${toString cdpPort},http://localhost:${toString cdpPort}"
        "--no-first-run"
        "--no-default-browser-check"
        "--password-store=basic"
        "--window-position=0,0"
        "--window-size=${toString width},${toString height}"
      ];
      # The profile and the downloads. Restart=always (onScreen) also
      # brings the browser back when someone closes its window from the VNC
      # page, which ends it cleanly.
      ReadWritePaths = [
        browserHome
        downloads
        "/tmp"
      ];
      # Downloads readable by the group (the agent).
      UMask = "0007";
      # SIGTERM to the browser process alone, which then closes its
      # renderers and flushes the profile; a signal to the whole group
      # kills them all at once and Chromium counts it as a crash.
      KillMode = "mixed";
      TimeoutStopSec = "30s";
    };
  };

  # The screen over VNC, on localhost only, with no VNC password: whoever
  # reaches x11vnc controls the screen. What keeps everyone else out is the
  # Kanidm sign-in in front of the page on adam, and in here the firewall
  # below, which lets only websockify connect to x11vnc. -noshm: X shared
  # memory between two users is refused; plain requests do on localhost.
  # -nopw: no warning about the missing password, which is deliberate.
  systemd.services.sivrad-vnc = lib.recursiveUpdate onScreen {
    description = "VNC server for sivrad's browser screen";
    serviceConfig = {
      User = "sivrad-vnc";
      Group = "sivrad-vnc";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.x11vnc}/bin/x11vnc"
        "-display ${display}"
        "-localhost -rfbport 5900"
        "-nopw -forever -shared -noshm -norc -quiet"
      ];
    };
  };

  # noVNC: websockify serves the page and relays its WebSocket to x11vnc.
  # It listens everywhere; the firewall below opens the port to adam's end
  # of the veth alone, where oauth2-proxy (sivrad-browser, ./default.nix) is
  # the one client. Plain HTTP over the veth: TLS ends at adam's nginx.
  systemd.services.sivrad-novnc = {
    description = "noVNC page for sivrad's browser screen";
    wantedBy = [ "multi-user.target" ];
    after = [ "sivrad-vnc.service" ];
    serviceConfig = {
      User = "sivrad-novnc";
      Group = "sivrad-novnc";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.python3Packages.websockify}/bin/websockify"
        "--web ${novncWeb} --file-only"
        "0.0.0.0:${toString novncPort} 127.0.0.1:5900"
      ];
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      UMask = "0077";
    };
  };

  # DevTools for money's server on adam (koon-apps' money: Costco's receipts
  # read in the profile people sign in to, and amazon-orders' sign-in
  # challenges), relayed from the container's address to loopback, where
  # the browser listens. Whoever reaches it drives the browser, as whoever
  # reaches the noVNC page does; the firewall below opens it to adam's end
  # of the veth alone, the same as the page. Chrome names the WebSocket it
  # answers with from the Host the client asked, so a client's addresses
  # come back by way of this relay.
  systemd.services.sivrad-cdp-relay = {
    description = "sivrad's browser DevTools, relayed for adam";
    wantedBy = [ "multi-user.target" ];
    after = [ "sivrad-chromium.service" ];
    serviceConfig = {
      User = "sivrad-cdp-relay";
      Group = "sivrad-cdp-relay";
      ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString cdpRelayPort},fork,reuseaddr TCP:127.0.0.1:${toString cdpPort}";
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  # Who reaches what. In: the noVNC page from adam's end of the veth only
  # (eth0, hostAddress), not from the tailnet or anywhere else. Out, from
  # inside the container itself, by the connecting user (the owner match,
  # xt_owner, which ./_host.nix loads on adam): x11vnc for websockify
  # alone, the page for nobody, and DevTools for the agent alone: every
  # process in the container may otherwise connect to loopback ports, and
  # none of the three asks for a password.
  networking.firewall.extraCommands = ''
    iptables -w -A nixos-fw -i eth0 -s ${hostAddress} -p tcp --dport ${toString novncPort} -j nixos-fw-accept
    iptables -w -A nixos-fw -i eth0 -s ${hostAddress} -p tcp --dport ${toString cdpRelayPort} -j nixos-fw-accept

    ip46tables -D OUTPUT -o lo -j sivrad-screen 2>/dev/null || true
    ip46tables -F sivrad-screen 2>/dev/null || true
    ip46tables -X sivrad-screen 2>/dev/null || true
    ip46tables -N sivrad-screen
    ip46tables -A sivrad-screen -p tcp --dport 5900 -m owner --uid-owner sivrad-novnc -j RETURN
    ip46tables -A sivrad-screen -p tcp --dport 5900 -j DROP
    ip46tables -A sivrad-screen -p tcp --dport ${toString novncPort} -j DROP
    ip46tables -A sivrad-screen -p tcp --dport ${toString cdpPort} -m owner --uid-owner sivrad -j RETURN
    ip46tables -A sivrad-screen -p tcp --dport ${toString cdpPort} -m owner --uid-owner sivrad-cdp-relay -j RETURN
    ip46tables -A sivrad-screen -p tcp --dport ${toString cdpPort} -j DROP
    ip46tables -A sivrad-screen -p tcp --dport ${toString cdpRelayPort} -j DROP
    ip46tables -I OUTPUT 1 -o lo -j sivrad-screen
  '';
  networking.firewall.extraStopCommands = ''
    ip46tables -D OUTPUT -o lo -j sivrad-screen 2>/dev/null || true
    ip46tables -F sivrad-screen 2>/dev/null || true
    ip46tables -X sivrad-screen 2>/dev/null || true
  '';
}
