{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.zero-cache;
  inherit (lib)
    mkEnableOption
    mkIf
    ;

  litestream = pkgs.buildGoModule rec {
    pname = "litestream-zero";
    version = "0.3.13+z0.0.6";

    src = pkgs.fetchFromGitHub {
      owner = "rocicorp";
      repo = "litestream";
      rev = "zero@v0.0.6";
      sha256 = "sha256-sBKmz2fBoYzYi1kUVeiugLBLPdqHc+fXCBkI8Cttakg=";
    };

    vendorHash = "sha256-PlfDJbhzbH/ZgtQ35KcB6HtPEDTDgss7Lv8BcKT/Dgg=";

    ldflags = [
      "-s"
      "-w"
      "-X main.Version=${version}"

      # nix does not like to build with this
      # "-extldflags '-static'"

    ];

    doCheck = false;

    tags = [
      "osusergo"
      "netgo"
      "sqlite_omit_load_extension"
    ];

    subPackages = [ "cmd/litestream" ];
  };

  zero-cache = pkgs.buildNpmPackage rec {
    name = "zero-cache";
    src = pkgs.fetchFromGitHub {
      owner = "rocicorp";
      repo = "mono";
      rev = "zero/v0.23.2025081401";
      hash = "sha256-NQcG/vnfUmle/6eNXXmnMqzNvniK8R/mO5RYdMX9pnE=";
    };

    npmDepsHash = "sha256-9vX9eODN8AfcLcMSjm6KzAAUmPIHfe2BILt0juya5us=";
    makeCacheWritable = true;
    npmFlags = [ "--legacy-peer-deps" ];
  };

in
{
  options = {
    services.zero-cache = {
      enable = mkEnableOption "Zero-cache, the server component of the Zero sync engine.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.zero-cache = {
      description = "Zero Cache";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${zero-cache}/bin/zero-cache";
        RemainAfterExit = true;
      };
    };
  };
}

