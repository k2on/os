{ ... }: {
  services.radicale = {
    enable = true;
    settings = {
      auth.type = "none";
      server.hosts = [ "0.0.0.0:5232" ];
    };
  };
}
