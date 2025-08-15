{ pkgs, config, ... }: {

  sops.secrets.max-password.neededForUsers = true;
  users.mutableUsers = false;

  users.users.max = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets.max-password.path;
    extraGroups = [ "wheel" "networkmanager" "video" "wireshark" "kvm" ];
    packages = with pkgs; [ tree ];
    shell = pkgs.zsh;
  };
}
