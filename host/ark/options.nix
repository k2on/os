{ lib, ... }: {
  options.oauth = {
    name = lib.mkOption { type = lib.types.str; };
    secrets = lib.mkOption { type = lib.types.attrs; };
  };

}
