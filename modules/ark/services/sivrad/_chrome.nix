# A real, headed browser for sivrad, next to the headless Playwright one
# (./_browser.nix): ungoogled-chromium with the Claude in Chrome extension,
# which Claude Code drives through its claude-in-chrome tools (`claude
# --chrome`, ./_guest.nix). Sites that turn the headless browser away
# usually let this one in, and a person can watch it and take over (sign
# in, solve a CAPTCHA) from a web page: noVNC on the tailnet.
#   imports = [ (import ./_chrome.nix { inherit home profile ...; }) ];
#
# The pieces, each a systemd service in the guest:
#   - sivrad-display: Xvfb, a virtual X screen (:1); sivrad-wm on it:
#     matchbox, a window manager that keeps one window full-screen with no
#     decorations, as a kiosk does;
#   - sivrad-chromium: the browser on that screen, as `sivrad`, with its
#     profile (sign-ins) under the home;
#   - sivrad-vnc: x11vnc, which shares the screen on localhost:5900 behind a
#     VNC password (the sivrad_vnc_password secret, ./default.nix);
#   - sivrad-novnc: websockify serving noVNC, the VNC client as a web page,
#     on port 6080, which the guest's firewall opens on tailscale0 only.
#
# How Claude Code reaches the browser: the extension asks Chromium for the
# native messaging host com.anthropic.claude_code_browser_extension, whose
# manifest names a program; Chromium starts it (`claude
# --chrome-native-host`), and it opens a socket in
# /tmp/claude-mcp-browser-bridge-<user>/, which the Claude Code session
# finds and connects to. So the browser and the session must run as the same
# user and share /tmp (no PrivateTmp on either). Claude Code writes that
# manifest itself, on every start, under ~/.config/<browser>/; here it is
# declared system-wide instead (/etc/chromium/native-messaging-hosts) and
# policy makes Chromium read only the system-wide ones.
#
# Why ungoogled-chromium installs the extension differently: the usual
# declarative way, the ExtensionInstallForcelist policy
# (programs.chromium.extensions), makes Chromium download the extension
# from the Web Store's update service, and ungoogled-chromium has taken
# that downloader out (its disable-webstore-urls patch: no update checks
# at all). What it keeps is Linux's external extensions: a JSON file per
# extension in /usr/share/chromium/extensions (nixpkgs rewrites /usr to
# /run/current-system/sw) naming a CRX file and its version, which Chromium
# installs from disk when the profile loads. The CRX is the Web Store's
# own, signed by it (so the extension keeps its Web Store ID, which the
# native host manifest allows), fetched and pinned here by hash. It never
# updates by itself; a new version is a new url and hash below.
#
# Not declarative: the extension's sign-in. Once, through the noVNC page,
# someone opens the extension and signs in to claude.ai with the account
# Claude Code is logged in with (`ark service sivrad init`); see the steps
# at the top of ./_guest.nix. The sign-in lives in the profile.
{
  home,
  # The browser's profile directory, kept between restarts.
  profile,
  # The X display the browser runs on, and the port of the noVNC page.
  display,
  vncPort,
}:
{ lib, pkgs, ... }:
let
  # The Claude extension's ID in the Chrome Web Store, and so in the
  # browser: its key is in the extension's manifest, so the ID is the same
  # however it is installed.
  extensionId = "fcoeoabgfenejglbffodgkkbkcdhcgfn";
  # The extension as the Web Store serves it. To update: the redirect from
  #   curl -sI 'https://clients2.google.com/service/update2/crx?response=redirect&acceptformat=crx3&prodversion=152.0&x=id%3Dfcoeoabgfenejglbffodgkkbkcdhcgfn%26installsource%3Dondemand%26uc'
  # is the current version's url; the version is in its file name. Claude
  # Code needs 1.0.36 or later.
  extension = rec {
    version = "1.0.100";
    crx = pkgs.fetchurl {
      name = "claude-in-chrome-${version}.crx";
      url = "https://clients2.googleusercontent.com/crx/blobs/AZPVhcTWxTETBUNTS9JPpiS0KzzRHArl7PwnnA9spn6VPBs9xxAc3lydKKMtKLWr0KaKYdAzAwX6jOpr6wuCeud7Nr14JLvRpOmpljbzhIozTDZqdZ2F6ClAVIsUAuX4J9tSAMZSmuXHl01I9RFeqKW0azLGRep5tZsQsQ/FCOEOABGFENEJGLBFFODGKKBKCDHCGFN_1_0_100_0.crx";
      hash = "sha256-gSy/373iq2AedIUGjq3Vkao84loZfYqt7bBpqv4f83o=";
    };
  };
  # The external extension file. user_type: Chromium only installs it for
  # the kinds of profile listed, and a browser under machine policy may
  # count as "managed".
  externalExtension = pkgs.writeTextDir "share/chromium/extensions/${extensionId}.json" (
    builtins.toJSON {
      external_crx = "${extension.crx}";
      external_version = extension.version;
      user_type = [
        "unmanaged"
        "managed"
      ];
    }
  );

  # The native messaging host, as Claude Code itself would declare it (name,
  # description, the one extension allowed to start it), but pointing at
  # the guest's claude-code rather than at a wrapper Claude Code writes into
  # ~/.claude/chrome. Chromium starts it with the browser's environment.
  nativeHost = "com.anthropic.claude_code_browser_extension";
  nativeHostProgram = pkgs.writeShellScript "sivrad-chrome-native-host" ''
    exec ${pkgs.claude-code}/bin/claude --chrome-native-host
  '';
  nativeHostManifest = {
    name = nativeHost;
    description = "Claude Code Browser Extension Native Host";
    path = "${nativeHostProgram}";
    type = "stdio";
    allowed_origins = [ "chrome-extension://${extensionId}/" ];
  };

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

  # Fonts for real pages: fontconfig is off in the guest (see browserFonts
  # in ./_guest.nix); Liberation stands in for Arial, Times and Courier.
  fonts = pkgs.makeFontsConf {
    fontDirectories = [
      pkgs.dejavu_fonts
      pkgs.liberation_ttf
    ];
  };

  # noVNC's page, and an index that opens it connected and scaled to the
  # window, so the URL to hand out is just http://sivrad:<port>/.
  novncWeb = pkgs.runCommand "sivrad-novnc-web" { } ''
    mkdir $out
    ln -s ${pkgs.novnc}/share/webapps/novnc/* $out/
    cat > $out/index.html <<'EOF'
    <!doctype html>
    <meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=scale&reconnect=true">
    EOF
  '';

  # What the services drawing on or reading the screen share: they start
  # with it, stop and restart with it, and wait for its socket. Hardening
  # as in sivrad.service (./_guest.nix); the container is the boundary.
  # (BindsTo stops them with the screen; being wanted by it starts them
  # again when it comes back.)
  onScreen = {
    wantedBy = [
      "multi-user.target"
      "sivrad-display.service"
    ];
    after = [ "sivrad-display.service" ];
    bindsTo = [ "sivrad-display.service" ];
    environment.DISPLAY = display;
    serviceConfig = {
      ExecStartPre = waitForDisplay;
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true; # /home and /root; the home is under /var/lib
      UMask = "0077";
    };
  };
  # The same, as sivrad, sharing /tmp: Xvfb's socket is there, and so is
  # the native host's (see above).
  asSivrad = lib.recursiveUpdate onScreen {
    environment.HOME = home;
    serviceConfig = {
      User = "sivrad";
      Group = "sivrad";
      PrivateTmp = false;
    };
  };
in
{
  # The policies, in /etc/chromium/policies/managed. programs.chromium
  # installs no browser, it only writes these files. No `extensions`
  # (ExtensionInstallForcelist): see the top of this file.
  programs.chromium = {
    enable = true;
    extraOpts = {
      # The Claude extension and nothing else; pinned to the toolbar so
      # whoever signs it in finds it.
      ExtensionSettings = {
        "*" = {
          installation_mode = "blocked";
          blocked_install_message = "This browser only runs the Claude extension (modules/ark/services/sivrad/_chrome.nix).";
        };
        ${extensionId} = {
          installation_mode = "allowed";
          toolbar_pin = "force_pinned";
        };
      };
      # Spelled out, as the extension arrives as an external extension.
      BlockExternalExtensions = false;
      # Only the system-wide native messaging hosts, and only Claude Code's.
      # Claude Code still writes its own manifest into the profile on every
      # start; this keeps the declared one in charge.
      NativeMessagingUserLevelHosts = false;
      NativeMessagingBlocklist = [ "*" ];
      NativeMessagingAllowlist = [ nativeHost ];

      # No Google account, sync or metrics (ungoogled-chromium has none of
      # these anyway; the policies say so for the next browser too).
      BrowserSignin = 0;
      SyncDisabled = true;
      MetricsReportingEnabled = false;
      SearchSuggestEnabled = false;
      # Sign-ins stay as cookies in the profile; passwords someone types
      # while taking over are not saved, nor addresses or cards.
      PasswordManagerEnabled = false;
      AutofillAddressEnabled = false;
      AutofillCreditCardEnabled = false;
      PaymentMethodQueryEnabled = false;
      # Nobody to answer a site asking for these.
      DefaultNotificationsSetting = 2;
      DefaultGeolocationSetting = 2;
      AudioCaptureAllowed = false;
      VideoCaptureAllowed = false;
      # Downloads go to the workspace, where the model may read and send
      # them, without a dialog.
      DownloadDirectory = "${home}/workspace/downloads";
      PromptForDownloadLocation = false;
      DefaultBrowserSettingEnabled = false;
      BackgroundModeEnabled = false;
      # No GPU in the container.
      HardwareAccelerationModeEnabled = false;
    };
  };

  environment.etc."chromium/native-messaging-hosts/${nativeHost}.json".text =
    builtins.toJSON nativeHostManifest;

  # The external extension file, under /run/current-system/sw/share/chromium.
  environment.systemPackages = [ externalExtension ];
  environment.pathsToLink = [ "/share/chromium" ];

  systemd.tmpfiles.rules = [
    # ~/.config first, or tmpfiles would make it root's on the way.
    "d ${home}/.config 0700 sivrad sivrad -"
    "d ${profile} 0700 sivrad sivrad -"
    "d ${home}/workspace/downloads 0700 sivrad sivrad -"
    # Xvfb runs as sivrad, so the directory for its socket must already be
    # there, world-writable and sticky as X expects.
    "d /tmp/.X11-unix 1777 root root -"
    # The native host's socket directory, made ahead so that the model's
    # sandbox, which hides it (./_guest.nix), finds it there to hide.
    "d /tmp/claude-mcp-browser-bridge-sivrad 0700 sivrad sivrad -"
  ];

  # The virtual screen. Xvfb takes no clients over TCP and has no
  # authorization file, so any process in the container may connect over
  # its socket in /tmp/.X11-unix: those running as sivrad, and x11vnc under
  # its own user. The model's sandbox does not see that directory
  # (./_guest.nix), so its commands cannot read the screen or type into it;
  # it acts on the browser through the extension, under Claude Code's
  # permissions.
  systemd.services.sivrad-display = {
    description = "Virtual X screen ${display} for sivrad's browser";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "sivrad";
      Group = "sivrad";
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
  # pop-ups (the claude.ai sign-in) on top of it; without a window manager
  # nothing would place or focus windows.
  systemd.services.sivrad-wm = lib.recursiveUpdate asSivrad {
    description = "Window manager on ${display}";
    serviceConfig.ExecStart = "${pkgs.matchbox}/bin/matchbox-window-manager -use_titlebar no";
  };

  systemd.services.sivrad-chromium = lib.recursiveUpdate asSivrad {
    description = "ungoogled-chromium with the Claude extension, on ${display}";
    after = [
      "sivrad-display.service"
      "sivrad-wm.service"
    ];
    environment = {
      FONTCONFIG_FILE = "${fonts}";
      # For the native host, which is Claude Code.
      DISABLE_AUTOUPDATER = "1";
    };
    serviceConfig = {
      # Chromium's own sandbox stays on: it builds it from user namespaces,
      # as bubblewrap does for the model's commands, so like sivrad.service
      # this unit sets nothing that would forbid them.
      #   --user-data-dir: the profile, at Chromium's default place
      #     (~/.config/chromium), where Claude Code looks to tell whether
      #     the extension is installed.
      #   --password-store=basic: no keyring in the container. The cookies
      #     are protected by the profile's permissions and the model's deny
      #     lists, not by a secret.
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.ungoogled-chromium}/bin/chromium"
        "--user-data-dir=${profile}"
        "--no-first-run"
        "--no-default-browser-check"
        "--password-store=basic"
        "--window-position=0,0"
        "--window-size=${toString width},${toString height}"
      ];
      # The profile, the downloads, and Claude Code's files for the native
      # host (its logs and configuration under ~/.claude). Restart=always
      # (onScreen) also brings the browser back when someone closes its
      # window from the VNC page, which ends it cleanly.
      ReadWritePaths = [
        home
        "/tmp"
      ];
    };
  };

  # The screen over VNC, on localhost only, behind the password. As a
  # dynamic user of its own, not as sivrad: the password (a copy of
  # /run/host-credentials/vnc_password, which only root may read, handed in
  # by systemd as a credential) then belongs to that user alone, out of
  # reach of anything running as sivrad, the model included. A dynamic user
  # gets a private /tmp, so the X socket is bound into it. -noshm: X shared
  # memory between two users is refused; plain requests do on localhost.
  systemd.services.sivrad-vnc = lib.recursiveUpdate onScreen {
    description = "VNC server for sivrad's browser screen";
    unitConfig.RequiresMountsFor = "/run/host-credentials";
    serviceConfig = {
      DynamicUser = true;
      BindPaths = [ "/tmp/.X11-unix" ];
      LoadCredential = [ "vnc-password:/run/host-credentials/vnc_password" ];
      # %d: the credentials directory.
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.x11vnc}/bin/x11vnc"
        "-display ${display}"
        "-localhost -rfbport 5900"
        "-passwdfile %d/vnc-password"
        "-forever -shared -noshm -norc -quiet"
      ];
    };
  };

  # noVNC: websockify serves the page and relays its WebSocket to x11vnc. It
  # listens everywhere; the guest's firewall opens the port on tailscale0
  # only (./_guest.nix), so the page is for the tailnet. Plain HTTP: the
  # tailnet is WireGuard, and the page asks for VNC's own password.
  systemd.services.sivrad-novnc = {
    description = "noVNC page for sivrad's browser screen";
    wantedBy = [ "multi-user.target" ];
    after = [ "sivrad-vnc.service" ];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.python3Packages.websockify}/bin/websockify"
        "--web ${novncWeb} --file-only"
        "0.0.0.0:${toString vncPort} localhost:5900"
      ];
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      UMask = "0077";
    };
  };
}
