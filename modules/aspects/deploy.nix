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
# ssh key, modules/keys/hosts/<name>.pub (named as modules/host/<name>), a
# read-only deploy key on max/secrets.
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
  giteaSshKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDesfZ/Iu620kNIIon3XKFcPM0QE4uzYtYkkgpuixXcyQtRxLufW1tJwWvRxQIB8HIwJTGewxFSo/TpSsr6s/lTTF++mMwI7ft3lPTQOX76RnCMZ5Z3w3Z7DHKxtqEMQZUsEYFs+MlIK1h4Agpk90HSIMMf+xRNiH6DYusDJJmMuuek2PhdA02VGekbBCnaXeVbCIatcIRxmH5gKtwetl7PAmzyluPRQaXGaesD7fk8aYDBKtElFg1DO1llazUbKrKRx2uQxRcPTIEB9uoXJXyv2M3or+ZoxPhVUcb1RH6RmoW1BPkFnDOb1JNFc66eo1IdDs5y/M2ujsbE2JPcEbX7O5BZA09A8fVWon2RYT74o8ary36g9LcV2MoadqgLH6AnAzut9D9XxCW9/zkJlPbAWwllA0NE3wBolEifpJRid/+x3/Quzbedxalsc0xsFJ3IzIYVTFnfJa9wuu1LalGAA61JkFYF/DHPs1ONShMvFxRgVo0KL/RJwKPyzunUVSbvR95THv4QFkMJPvJvn1mxRKoeWudQyOy75T4CcXfrxXRrx3kWAMkHdnu4SnJbe4egSdxnAHMzs/XrBy4FS2eyuGFzpG10Tl96sZgG2CF9N7l8g5LPCDl8anoEFUIc96fr0R8AX/AsmSvFd4Xgq3sQktpS8OMohpXz92T7MCeuFQ==";

  # Whose signatures deploy: every key listed in modules/keys/max.pub.
  signers = lib.filter (l: l != "") (lib.splitString "\n" (lib.fileContents ../keys/max.pub));
in
{
  den.aspects.deploy =
    { host, ... }:
    {
      nixos =
        { pkgs, ... }:
        {
          imports = [ inputs.comin.nixosModules.comin ];

          services.comin = {
            enable = true;
            # The flake's name for this host, which is not its hostName (adam is ark).
            hostname = host.name;
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
        };
    };
}
