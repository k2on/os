{ ... }:
{
  flake.homeModules.koonMaxGit =
    { lib, ... }:
    let
      publicGitEmail = "22125083+k2on@users.noreply.github.com";
      # Your keys, one per line (`ark id` adds them); signing is with the one on
      # this machine, which `ark id` keeps at OpenSSH's place for it.
      keys = lib.filter (l: l != "") (lib.splitString "\n" (lib.fileContents ../../../keys/max.pub));
      publicKey = "/home/max/.ssh/id_ed25519_sk.pub";
    in
    {
      programs.git = {
        enable = true;
        settings = {
          init.defaultBranch = "main";
          push.autoSetupRemote = true;

          commit.gpgsign = true;
          gpg.format = "ssh";

          user.name = "Max Koon";
          user.email = publicGitEmail;
          user.signing.key = publicKey;
          gpg.ssh.allowedSignersFile = "/home/max/.ssh/allowed_signers";
        };

        signing = {
          signByDefault = true;
          key = publicKey;
        };
      };

      home.file.".ssh/allowed_signers".text = lib.concatMapStrings (
        key: "${publicGitEmail} ${key}\n"
      ) keys;
    };
}
