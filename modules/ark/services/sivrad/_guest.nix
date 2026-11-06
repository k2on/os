# The `sivrad` container: an always-on assistant, Codex under systemd
# (./_codex.nix), fed by its own channel server (./channel, Rust).
# The family reaches it from the sivrad app on their phones and over Signal;
# both arrive through that channel, tagged with the same identity: their
# Kanidm username, which /etc/sivrad/people.json maps to their Signal number
# or username. That file comes from ark.persons.<name>.signal in
# secrets/ark.nix (see ./default.nix), so it changes with a deploy of adam
# and a restart of the container.
#
# First boot, from the owner's laptop (`ark service sivrad`, ./cli/mod.rs;
# it reaches the container as sivrad-channel@sivrad.<tailnet domain> over
# ssh):
#   1. `ark secrets`: the Tinfoil API key is entered by hand; the rest is
#      generated. Commit secrets/ and deploy adam.
#   2. `ark service sivrad init`: says who may use sivrad, checks the
#      services in the container are up, and says what is left.
#   3. Give the assistant its own Signal number:
#        ark service sivrad signal register +NUMBER   (asks for the SMS code)
#      It goes through the signal-cli daemon below, which loads the new
#      account at once, and save it to the secrets repo; commit secrets/ and
#      deploy adam so a rebuilt container restores it (restoreSignal). Its
#      profile, the name and the picture, is configuration: signalProfile in
#      ./default.nix, applied by signal-cli's post-start check below.
#   4. In the sivrad app on the phone, enter http://sivrad:8788 (MagicDNS)
#      and sign in with Kanidm.
# Only people in people.json get through, from either side.
#
# The channel listens on TCP 8788, reachable over tailscale0 only; the phone
# long-polls it (./channel/src/http.rs). Signal goes through signal-cli's
# JSON-RPC daemon on a socket (./channel/src/signal.rs), files included:
# received attachments end up in workspace/inbox, and the agent may attach
# workspace files to what it sends (./channel/src/files.rs). Each message
# is a turn of the agent over its app-server socket (./channel/src/codex.rs);
# the agent calls the channel back over MCP for the phone's tools and for
# Signal (./channel/src/mcp.rs).
#
# The model: sivrad-llm on loopback, today in front of Tinfoil's attesting
# proxy (./_llm.nix). The browser: ungoogled-chromium on a virtual screen,
# driven over DevTools through Playwright's MCP server, watched over noVNC
# (./_chrome.nix, ./_browser.nix).
#
# Three accounts share the container (./_container.nix): the agent
# (`sivrad`), the channel with the Signal account (`sivrad-channel`), the
# browser with its profile (`sivrad-browser`). The agent's shell commands
# run in Codex's sandbox as `sivrad`, so what they may read is what
# `sivrad` may read: its home and workspace, the tokens meant for it under
# /run/host-tokens, and nothing of the other two accounts'. The network
# bounds them all alike: the container and adam's egress policy.
#
# The container is a tailnet node of its own, `sivrad` under headscale's
# `ark` user, joining with adam's pre-auth key (see _host.nix for how the
# key gets here). What it may reach on the tailnet is headscale's ACL
# (follow-up); the key is reusable, so a dedicated key and user are a
# follow-up too.
#
# State (the agent's memory and sessions, signal-cli's account, the
# browser's profile, the tailnet node identity) lives on the host under
# /var/lib/nixos-containers/sivrad, the container's root, and survives
# rebuilds and restarts.
{
  lib,
  pkgs,
  loginServer,
  oidc,
  people,
  signalProfile,
  bot,
  browserPage,
  ...
}:
let
  inherit (import ./_container.nix)
    user
    channelUser
    browserUser
    home
    workspace
    channelHome
    browserHome
    signalDir
    signalSocket
    hostAddress
    ports
    codexSocket
    phonePort
    novncPort
    novncPrefix
    cdpRelayPort
    ;

  # Who may talk to sivrad, keyed by Kanidm username:
  #   { "alice": { "signal": "+15551234567" } }
  # The channel re-reads it on every request, but it only changes with the
  # guest's configuration (deploy adam, then restart the container).
  peopleJson = pkgs.writeText "sivrad-people.json" (builtins.toJSON people);

  channel = pkgs.callPackage ../../_rust.nix { pname = "sivrad-channel"; };

  sshKey = builtins.readFile ../../../aspects/key.pub;

  # One command per service the account may use: `home-api /states`, as
  # curl with the token from the file in the right header, so the agent's
  # commands carry no token.
  apiTools = lib.mapAttrsToList (
    name: s:
    pkgs.writeShellScriptBin "${name}-api" ''
      # ${name}'s REST API as the ${bot.name} account:
      #   ${name}-api <path> [curl options]      e.g. ${name}-api /user
      path=''${1:?usage: ${name}-api <path> [curl options]}
      shift
      exec ${pkgs.curl}/bin/curl -sS -H "${s.header} $(cat ${s.token})" "$@" "${s.url}${s.path}$path"
    ''
  ) bot.services;

  # Before the Signal account had an account of its own in the container,
  # signal-cli ran as the agent and kept its data under the agent's home.
  # Moved once, by root (ExecStartPre with `+`), so a registered number
  # survives the change; the backup in the secrets repo would do the same.
  legacySignalDir = "${home}/signal-cli";
  migrateSignal = pkgs.writeShellScript "sivrad-migrate-signal" ''
    set -eu
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
      ]
    }
    if [ -d ${legacySignalDir}/data ] && [ ! -d ${signalDir}/data ]; then
      echo "moving the Signal account from ${legacySignalDir} to ${signalDir}"
      # Into the directory, not over it: the unit's ReadWritePaths makes
      # signalDir a mount point in this namespace, which cannot be replaced.
      mkdir -p ${signalDir}
      find ${legacySignalDir} -mindepth 1 -maxdepth 1 -exec mv -t ${signalDir}/ {} +
      rmdir ${legacySignalDir} || true
      chown -R ${channelUser}:${channelUser} ${signalDir}
      chmod 0700 ${signalDir}
    fi
  '';

  # The Signal account saved by `ark service sivrad signal ...` (the
  # sivrad_signal_account secret, a base64 tar.gz of signalDir without its
  # attachment, avatar and sticker caches), unpacked when signalDir has no
  # account yet: a fresh container root. The host copies it in,
  # world-readable, as the daemon runs as sivrad-channel; empty until an
  # account has been saved. Unpacked aside and moved into place, so a
  # failed restore leaves no half account behind and runs again on the
  # next start; until then the daemon does not start (journalctl -u
  # signal-cli says why) rather than run without the account.
  restoreSignal = pkgs.writeShellScript "sivrad-restore-signal" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnutar
        pkgs.gzip
      ]
    }
    backup=/run/host-credentials/signal-account.tar.gz.b64
    if [ -e ${signalDir}/data ] || [ ! -s "$backup" ]; then
      exit 0
    fi
    echo "restoring the Signal account from $backup"
    tmp=$(mktemp -d ${signalDir}/.restore.XXXXXX)
    trap 'rm -rf "$tmp"' EXIT
    base64 -d "$backup" | tar -xzf - -C "$tmp"
    if [ ! -d "$tmp/data" ]; then
      echo "$backup holds no data/ directory; not restoring" >&2
      exit 1
    fi
    chmod -R go= "$tmp/data"
    mv "$tmp/data" ${signalDir}/data
  '';
in
{
  imports = [
    (import ./_llm.nix { inherit ports; })
    (import ./_codex.nix {
      inherit
        codexSocket
        home
        workspace
        user
        channelUser
        ports
        bot
        browserPage
        ;
      people = lib.attrNames people;
    })
    (import ./_chrome.nix {
      inherit
        browserUser
        browserHome
        workspace
        hostAddress
        novncPort
        novncPrefix
        cdpRelayPort
        ;
      legacyProfile = "${home}/.config/chromium";
      display = ":1";
      cdpPort = ports.cdp;
    })
  ];

  # eth0's address and the default route via adam come from nixos-containers
  # (_host.nix). Public resolvers rather than adam's resolv.conf: the host's
  # resolver is not reachable from the container's network namespace, and
  # the egress policy only forwards DNS to public addresses anyway.
  networking.useHostResolvConf = false;
  networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  # No services.tailscale.authKeyFile: the NixOS tailscaled-autoconnect unit
  # it would add is Type=notify and only reports ready once the node is
  # Running. Nothing in the guest's boot may wait for the network like
  # that: nixos-containers configures the host end of the veth in
  # container@sivrad's ExecStartPost, which runs once the guest's systemd
  # reports startup finished, and that waits for every unit of the boot.
  # The two would wait for each other until the host unit's one-minute
  # start timeout killed the container (it did). This plain service does
  # the same job outside of readiness: it keeps trying until the node runs,
  # and only logs in when the backend needs it.
  services.tailscale.enable = true;
  systemd.services.sivrad-tailnet = {
    description = "Join the tailnet with adam's pre-auth key";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" ];
    requires = [ "tailscaled.service" ];
    unitConfig.RequiresMountsFor = "/run/host-credentials";
    path = [
      pkgs.tailscale
      pkgs.jq
    ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 10;
    };
    script = ''
      while :; do
        state=$(tailscale status --json --peers=false | jq -r .BackendState)
        case "$state" in
          Running)
            echo "on the tailnet"
            exit 0
            ;;
          NeedsLogin | NeedsMachineAuth | Stopped)
            echo "logging in ($state)"
            tailscale up --auth-key "$(cat /run/host-credentials/headscale_preauth_key)" \
              --login-server ${lib.escapeShellArg loginServer} --timeout 30s || true
            ;;
          *)
            echo "waiting ($state)"
            ;;
        esac
        sleep 5
      done
    '';
  };

  # The phone reaches the channel over the tailnet only. The veth side
  # (adam) gets SSH and, from adam's own address, the noVNC page of the
  # headed browser, which people reach through adam (./_chrome.nix).
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ phonePort ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # The agent.
  users.users.${user} = {
    isNormalUser = true;
    uid = 1000;
    group = user;
    inherit home;
    openssh.authorizedKeys.keys = [ sshKey ];
  };
  users.groups.${user}.gid = 1000;
  # The channel and the Signal account; what `ark service sivrad` logs in
  # as. In the agent's group for the workspace.
  users.users.${channelUser} = {
    isSystemUser = true;
    group = channelUser;
    home = channelHome;
    shell = pkgs.bashInteractive;
    extraGroups = [ user ];
    openssh.authorizedKeys.keys = [ sshKey ];
  };
  users.groups.${channelUser} = { };

  environment.systemPackages =
    with pkgs;
    [
      signal-cli
      git
      ripgrep
      jq
      curl
      # The post-start check of signal-cli below talks to its socket.
      socat
      # One-time codes for the account's Kanidm sign-in (AGENTS.md,
      # ./_codex.nix).
      oath-toolkit
    ]
    ++ apiTools;

  environment.etc."sivrad/people.json".source = peopleJson;

  systemd.tmpfiles.rules = [
    "d ${channelHome} 0700 ${channelUser} ${channelUser} -"
    "d ${signalDir} 0700 ${channelUser} ${channelUser} -"
  ];

  # Signal for the channel: signal-cli's JSON-RPC daemon, multi-account
  # mode (no -a), on a socket only `sivrad-channel` can reach. It starts
  # receiving when the channel connects, so messages wait on Signal's
  # servers until then. Attachments are downloaded into
  # signalDir/attachments, from where the channel moves them into the
  # workspace's inbox for the agent; stories, avatars and stickers are not
  # fetched.
  systemd.services.signal-cli = {
    description = "signal-cli JSON-RPC daemon for sivrad";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = [
      channelHome
      "/run/host-credentials"
    ];
    serviceConfig = {
      User = channelUser;
      Group = channelUser;
      RuntimeDirectory = channelUser;
      RuntimeDirectoryMode = "0700";
      ExecStartPre = [
        "+${migrateSignal}"
        restoreSignal
      ];
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.signal-cli}/bin/signal-cli --config ${signalDir}"
        "daemon --socket ${signalSocket} --receive-mode on-connection"
        "--ignore-stories --ignore-avatars --ignore-stickers"
      ];
      # The daemon checks each account with the server as it loads it, and
      # when that fails (the network is not quite up yet at boot) it carries
      # on with no account at all, which looks healthy to systemd while the
      # channel can neither send nor receive. So this fails the start when
      # there is an account on disk that the daemon did not load, and
      # Restart= tries again.
      #
      # With the account loaded, it also sets the account's Signal profile
      # (name and picture: signalProfile, from ./default.nix). A stamp in
      # signalDir remembers what was applied, so the profile is uploaded
      # only when it changes, or after a fresh restore. A failed upload is
      # logged, not fatal: the next start tries again.
      ExecStartPost =
        let
          profile = {
            inherit (signalProfile) givenName;
          }
          // lib.optionalAttrs (signalProfile.avatar != null) { avatar = "${signalProfile.avatar}"; };
          wanted = pkgs.writeText "sivrad-signal-profile.json" (builtins.toJSON profile);
        in
        pkgs.writeShellScript "sivrad-signal-cli-loaded" ''
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.jq
              pkgs.socat
            ]
          }
          registered=$(jq -r '.accounts | length' ${signalDir}/data/accounts.json 2>/dev/null || echo 0)
          if [ "''${registered:-0}" -lt 1 ]; then
            exit 0 # nothing registered yet
          fi
          for _ in $(seq 1 60); do
            [ -S ${signalSocket} ] && break
            sleep 1
          done
          rpc() {
            printf '%s\n' "$1" | socat -t 60 - UNIX-CONNECT:${signalSocket} | jq -c 'select(.id == 1)' | head -1
          }
          accounts=$(rpc '{"jsonrpc":"2.0","id":1,"method":"listAccounts","params":{}}')
          account=$(printf '%s' "$accounts" | jq -r '.result[0].number // .result[0].aci // empty')
          if [ -z "$account" ]; then
            echo "signal-cli loaded no account (see its log above); restarting" >&2
            exit 1
          fi

          stamp=${signalDir}/profile.applied
          if [ -e "$stamp" ] && cmp -s "$stamp" ${wanted}; then
            exit 0
          fi
          request=$(jq -c --arg account "$account" '{jsonrpc: "2.0", id: 1, method: "updateProfile", params: (. + {account: $account})}' ${wanted})
          answer=$(rpc "$request")
          if [ -z "$answer" ] || printf '%s' "$answer" | jq -e '.error' >/dev/null; then
            echo "updateProfile failed: ''${answer:-no answer from signal-cli}" >&2
            exit 0
          fi
          install -m 0600 ${wanted} "$stamp"
          echo "Signal profile applied"
        '';
      # Also after a plain exit. Accounts registered through the
      # daemon (`ark service sivrad signal`) load without a restart.
      Restart = "always";
      RestartSec = "10s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ signalDir ];
      PrivateTmp = true;
      ProtectHome = true;
      UMask = "0077";
    };
  };

  # The channel: the phone's HTTP server on the tailnet, the MCP endpoint
  # for the agent on loopback, and the Signal side through the socket
  # above. It drives the agent through its app-server socket (./_codex.nix)
  # and remembers which thread is which chat's in its own home.
  systemd.services.sivrad-channel = {
    description = "Sivrad's channel: the phone, Signal, and the agent";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "signal-cli.service"
    ];
    wants = [
      "network-online.target"
      "signal-cli.service"
    ];
    unitConfig.RequiresMountsFor = [
      home
      channelHome
    ];
    environment = {
      SIVRAD_LISTEN = "0.0.0.0:${toString phonePort}";
      SIVRAD_MCP_LISTEN = "127.0.0.1:${toString ports.mcp}";
      SIVRAD_CODEX_SOCKET = codexSocket;
      SIVRAD_THREADS_FILE = "${channelHome}/threads.json";
      SIVRAD_OIDC_ISSUER = oidc.issuer;
      SIVRAD_OIDC_CLIENT = oidc.clientId;
      SIVRAD_PEOPLE_FILE = "/etc/sivrad/people.json";
      SIVRAD_SIGNAL_SOCKET = signalSocket;
      # Files over Signal: received attachments (signal-cli saves them
      # under signalDir, which the agent may not read) are moved to
      # workspace/inbox; only workspace files may be sent.
      SIVRAD_WORKSPACE = workspace;
      SIVRAD_SIGNAL_ATTACHMENTS = "${signalDir}/attachments";
    };
    serviceConfig = {
      User = channelUser;
      Group = channelUser;
      ExecStart = "${channel}/bin/sivrad-channel";
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        workspace
        signalDir
        channelHome
      ];
      ProtectHome = true;
      PrivateTmp = true;
      # Files it puts in the inbox are the agent's to read.
      UMask = "0007";
    };
  };

  # systemd-nspawn masks a dozen paths under /proc (/proc/sys bound
  # read-only, /proc/kmsg, /proc/kcore, /proc/sysrq-trigger ... hidden
  # under tmpfs). The kernel refuses a fresh procfs mount from inside a user
  # namespace while the visible procfs carries such over-mounts, so
  # bubblewrap, which Codex's sandbox needs, fails with "Can't mount proc
  # on /proc", and Chromium's sandbox, built the same way, runs into it
  # too. Take the masks off. They only kept the sysctls from container root, who shares
  # the host's uid 0 and holds CAP_SYS_ADMIN anyway (privateUsers = "no",
  # _host.nix); everyone else is bound by the files' own permissions as
  # before.
  systemd.services.sivrad-unmask-proc = {
    description = "Remove nspawn's /proc masks for sandboxes that mount procfs";
    wantedBy = [ "multi-user.target" ];
    # Not before the agent's socket: that sits in sockets.target, early in
    # the boot, and ordering it after a multi-user service makes a cycle
    # that systemd resolves by never starting the socket. The app-server
    # itself (sivrad@, ./_codex.nix) comes after this.
    before = [ "sivrad-chromium.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.util-linux
      pkgs.gawk
      pkgs.coreutils
    ];
    # Some paths are masked more than once (stacked mounts) and the list
    # names them once per layer, so a pass may try a path that the previous
    # umount already cleared; unmount until none are left, a few passes is
    # plenty.
    script = ''
      for _ in 1 2 3 4 5; do
        masks=$(awk '$5 ~ "^/proc/" { print $5 }' /proc/self/mountinfo | sort -r | uniq)
        [ -n "$masks" ] || exit 0
        for m in $masks; do
          umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        done
      done
      echo "mounts left under /proc:" >&2
      awk '$5 ~ "^/proc/" { print $5 }' /proc/self/mountinfo >&2
      exit 1
    '';
  };

  # Nothing in the guest builds or administers itself.
  nix.enable = false;
  documentation.enable = false;
  environment.defaultPackages = [ ];
  programs.command-not-found.enable = false;
  security.sudo.enable = false;
  services.logrotate.enable = false;
  services.udisks2.enable = false;
  fonts.fontconfig.enable = false;
  xdg = {
    autostart.enable = false;
    icons.enable = false;
    menus.enable = false;
    mime.enable = false;
    sounds.enable = false;
  };
  boot.enableContainers = false;
  systemd.coredump.enable = false;

  time.timeZone = "America/Chicago";
  system.stateVersion = "26.05";
}
