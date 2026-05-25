{ ... }: {
  flake.nixosModules.commonFeatureLaptop = { ... }: {
    services.upower.enable = true;
    services.logind.settings.Login.HandlePowerKey = "ignore";
    services.automatic-timezoned.enable = true;
  };
}
