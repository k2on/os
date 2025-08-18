{ lib, ... }:
let
  publicGitEmail = "22125083+k2on@users.noreply.github.com";
  publicKey = "/home/max/.ssh/id_maxkey.pub";
in
{
  programs.git = {
    enable = true;
    userName = "Max Koon";
    userEmail = publicGitEmail;
    extraConfig = {
      init.defaultBranch = "main";
      push.autoSetupRemote = true;

      commit.gpgsign = true;
      gpg.format = "ssh";
      user.signing.key = publicKey;
      gpg.ssh.allowedSignersFile = "/home/max/.ssh/allowed_signers";
    };

    signing = {
      signByDefault = true;
      key = publicKey;
    };
  };

  home.file.".ssh/allowed_signers".text = ''
    ${publicGitEmail} ${lib.fileContents ../keys/id_maxkey.pub}
  '';
}
