{ ... }:
{
  den.aspects.hcloud-ssh-key = {
    terranix = {
      resource.hcloud_ssh_key.default = {
        name = "my-ssh-key";
        public_key = builtins.readFile ./key.pub;
      };
    };
  };
}
