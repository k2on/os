# The `assistant` microVM: an always-on Claude Code session fed by a Signal
# channel plugin, running in tmux under systemd.
#
# First boot (from adam):
#   1. ssh assistant@192.168.77.2
#   2. tmux attach -t claude, then complete the `claude` login (browser flow).
#   3. In Claude: /plugin marketplace add bufothefrog/claude-signal
#                 /plugin install signal@claude-signal
#   4. Detach, then link Signal: `signal-cli link -n assistant` (scan the QR
#      code) or register a dedicated number with `signal-cli -u +NUMBER
#      register` / `verify`.
#   5. Restart the session (`/exit` in Claude; systemd restarts it), accept
#      the development-channel warning, then pair from the phone and run
#      /signal:access pair <code> and /signal:access policy allowlist.
#
# The development-channel warning appears on every start, so after a VM or
# service restart someone has to attach and accept it.
{ lib, pkgs, ... }:
let
  mac = "02:00:00:77:00:02";
  home = "/var/lib/assistant";

  claude = pkgs.writeShellScript "assistant-claude" ''
    exec claude --dangerously-load-development-channels plugin:signal@claude-signal
  '';
  # `tmux -D` keeps the server in the foreground for systemd but takes no
  # command, so the session comes from this config; exit-empty (which -D
  # turns off) makes the server exit with Claude, so systemd restarts both.
  tmuxConf = pkgs.writeText "assistant-tmux.conf" ''
    set -s exit-empty on
    new-session -d -s claude -c ${home}/workspace ${claude}
  '';
in
{
  microvm = {
    hypervisor = "cloud-hypervisor";
    vcpu = 2;
    mem = 2048;
    # Lets cloud-hypervisor report readiness to systemd; unique per host.
    vsock.cid = 3;
    # Boot from the host's /nix/store, shared read-only.
    shares = [
      {
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        proto = "virtiofs";
        readOnly = true;
      }
    ];
    # Persistent state on a block device: signal-cli and Claude Code use
    # SQLite and need reliable locking.
    volumes = [
      {
        image = "state.img";
        mountPoint = home;
        size = 4096;
        fsType = "ext4";
      }
    ];
    interfaces = [
      {
        type = "tap";
        id = "vm-assistant";
        inherit mac;
      }
    ];
  };

  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";

  # microvm.nix defaults guests to networkd; match the NIC by MAC because the
  # name depends on its PCI slot.
  networking.useDHCP = false;
  systemd.network.networks."10-eth" = {
    matchConfig.MACAddress = mac;
    address = [ "192.168.77.2/24" ];
    gateway = [ "192.168.77.1" ];
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.assistant = {
    isNormalUser = true;
    uid = 1000;
    inherit home;
    openssh.authorizedKeys.keys = [ (builtins.readFile ../../aspects/key.pub) ];
  };

  environment.systemPackages = with pkgs; [
    claude-code
    tmux
    bun
    signal-cli
    git
  ];

  # The volume is mounted after users are created, so fix ownership here.
  systemd.tmpfiles.rules = [
    "d ${home} 0700 assistant users -"
    "d ${home}/workspace 0700 assistant users -"
  ];

  systemd.services.assistant = {
    description = "Claude Code assistant (tmux session `claude`)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = home;
    path = [ "/run/current-system/sw" ];
    environment = {
      HOME = home;
      SHELL = "${pkgs.bashInteractive}/bin/bash";
      TERM = "xterm-256color";
    };
    serviceConfig = {
      User = "assistant";
      WorkingDirectory = "${home}/workspace";
      ExecStart = "${pkgs.tmux}/bin/tmux -D -f ${tmuxConf}";
      Restart = "always";
      RestartSec = "30s";
    };
  };

  time.timeZone = "America/Chicago";
  system.stateVersion = "26.05";
}
