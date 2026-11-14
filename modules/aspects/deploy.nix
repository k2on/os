# Every host deploys itself: comin polls main and switches to it as root, so
# nothing pushes to a host or needs to sign in to one to deploy.
#
# It deploys only commits signed by one of modules/keys/max.pub (the keys
# `ark id` makes on a YubiKey), so whoever can push to Gitea or GitHub still
# cannot change a host. Pushing to testing-<host> tries a commit there first:
# `switch-to-configuration test`, so the bootloader keeps the last main and a
# reboot goes back to it.
#
# The repo is public and fetched over HTTPS, from Gitea and GitHub alike.
# Its secrets submodule is not: Nix fetches it (comin evaluates with
# submodules) as root through ssh, signing in to Gitea with the host's own
# ssh key, modules/keys/hosts/<host>.pub, a read-only deploy key on
# max/secrets.
#
# There is no order between hosts: each takes main when it sees it. A change
# that one host depends on another for (a rename) goes in two commits, the
# new thing first.
{
  inputs,
  config,
  lib,
  ...
}:
let
  ark = config.ark;
  gitea = "git.${ark.mainDomain}";
  giteaSsh = "ssh.${ark.mainDomain}";
  # Gitea's own ssh server (services/git), whose key is in its data directory.
  giteaSshPort = 2222;
  # comin-log (below): its latest log line, beside comin's metrics on 4243.
  cominLogPort = 4244;
  giteaSshKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDesfZ/Iu620kNIIon3XKFcPM0QE4uzYtYkkgpuixXcyQtRxLufW1tJwWvRxQIB8HIwJTGewxFSo/TpSsr6s/lTTF++mMwI7ft3lPTQOX76RnCMZ5Z3w3Z7DHKxtqEMQZUsEYFs+MlIK1h4Agpk90HSIMMf+xRNiH6DYusDJJmMuuek2PhdA02VGekbBCnaXeVbCIatcIRxmH5gKtwetl7PAmzyluPRQaXGaesD7fk8aYDBKtElFg1DO1llazUbKrKRx2uQxRcPTIEB9uoXJXyv2M3or+ZoxPhVUcb1RH6RmoW1BPkFnDOb1JNFc66eo1IdDs5y/M2ujsbE2JPcEbX7O5BZA09A8fVWon2RYT74o8ary36g9LcV2MoadqgLH6AnAzut9D9XxCW9/zkJlPbAWwllA0NE3wBolEifpJRid/+x3/Quzbedxalsc0xsFJ3IzIYVTFnfJa9wuu1LalGAA61JkFYF/DHPs1ONShMvFxRgVo0KL/RJwKPyzunUVSbvR95THv4QFkMJPvJvn1mxRKoeWudQyOy75T4CcXfrxXRrx3kWAMkHdnu4SnJbe4egSdxnAHMzs/XrBy4FS2eyuGFzpG10Tl96sZgG2CF9N7l8g5LPCDl8anoEFUIc96fr0R8AX/AsmSvFd4Xgq3sQktpS8OMohpXz92T7MCeuFQ==";

  # Whose signatures deploy: every key listed in modules/keys/max.pub.
  signers = lib.filter (l: l != "") (lib.splitString "\n" (lib.fileContents ../keys/max.pub));
in
{
  den.aspects.deploy = {
    nixos =
      { pkgs, ... }:
      {
        imports = [ inputs.comin.nixosModules.comin ];

        services.comin = {
          enable = true;
          submodules = true;
          remotes = [
            {
              name = "gitea";
              url = "https://${gitea}/max/os.git";
            }
            {
              name = "github";
              url = "https://github.com/k2on/os.git";
            }
          ];
          # The last 5 deployments stay bootable, as the plain system profile's
          # (aspects/gc.nix).
          retention = {
            deployment_boot_entry_capacity = 5;
            deployment_successful_capacity = 5;
            deployment_any_capacity = 5;
          };
          sshAllowedSignersPath = "${pkgs.writeText "comin-allowed-signers" (
            lib.concatMapStrings (key: "max namespaces=\"git\" ${key}\n") signers
          )}";
        };

        # Nix fetches the submodule with git; comin's unit has only nix and ssh.
        systemd.services.comin.path = [ pkgs.git ];

        # Root's way into Gitea for the submodule: the host key, nobody else's.
        programs.ssh.extraConfig = ''
          Match host ${giteaSsh} localuser root
            IdentityFile /etc/ssh/ssh_host_ed25519_key
            IdentitiesOnly yes
        '';
        programs.ssh.knownHosts.gitea = {
          hostNames = [ "[${giteaSsh}]:${toString giteaSshPort}" ];
          publicKey = giteaSshKey;
        };

        # comin's latest log line over the tailnet, for `ark push` to show by
        # each host it's waiting on: comin itself serves only metrics over
        # HTTP. A connection runs journalctl once and gets the line back.
        systemd.sockets.comin-log = {
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = cominLogPort;
            Accept = true;
          };
        };
        systemd.services."comin-log@" = {
          description = "comin's latest log line, for ark push";
          serviceConfig = {
            StandardInput = "socket";
            StandardOutput = "socket";
            DynamicUser = true;
            SupplementaryGroups = [ "systemd-journal" ];
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
            RuntimeMaxSec = 10;
          };
          path = [
            pkgs.systemd
            pkgs.gnugrep
            pkgs.gnused
            pkgs.coreutils
          ];
          script = ''
            # The request: read and ignored, there's one answer.
            read -r -t 2 _ || true
            # Its message, without comin's prefix, nor its relayed metric
            # events ("broker: dropped event ...").
            line=$(journalctl -u comin -n 200 -o cat --no-pager \
              | grep -v 'dropped event for subscriber' \
              | sed -E 's/^time="[^"]*" level=[a-z]+ msg=//; s/^"//; s/"$//; s/\\"/"/g' \
              | tail -n 1)
            printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s\n' "$line"
          '';
        };
        networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cominLogPort ];
      };
  };
}
