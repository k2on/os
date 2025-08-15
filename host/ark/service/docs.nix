{ config, lib, pkgs, ... }: {
  nixpkgs.config.allowUnfree = true;

  services.outline = {
    enable = true;
    publicUrl = "https://docs.koon.us";
    port = 3004;
    forceHttps = true;
    storage.storageType = "local";
    logo = "https://i.imgur.com/fKJ1I63.png";
    oidcAuthentication = {
      authUrl = "https://auth.koon.us/authorize";
      tokenUrl = "https://auth.koon.us/api/oidc/token";
      userinfoUrl = "https://auth.koon.us/api/oidc/userinfo";
      clientId = "";
      clientSecretFile = config.sops.secrets."docs/clientSecret".path;
      scopes = [ "openid" "email" "profile" ];
      usernameClaim = "preferred_username";
      displayName = config.oauth.name;
    };
  };

  systemd.services.outline = {
    script =
      let
        localPostgresqlUrl = "postgres://localhost/outline?host=/run/postgresql";
        cfg = config.services.outline;
      in lib.mkForce ''
          export SECRET_KEY="$(head -n1 ${lib.escapeShellArg cfg.secretKeyFile})"
          export UTILS_SECRET="$(head -n1 ${lib.escapeShellArg cfg.utilsSecretFile})"
          ${lib.optionalString (cfg.storage.storageType == "s3") ''
            export AWS_SECRET_ACCESS_KEY="$(head -n1 ${lib.escapeShellArg cfg.storage.secretKeyFile})"
          ''}
          ${lib.optionalString (cfg.slackAuthentication != null) ''
            export SLACK_CLIENT_SECRET="$(head -n1 ${lib.escapeShellArg cfg.slackAuthentication.secretFile})"
          ''}
          ${lib.optionalString (cfg.googleAuthentication != null) ''
            export GOOGLE_CLIENT_SECRET="$(head -n1 ${lib.escapeShellArg cfg.googleAuthentication.clientSecretFile})"
          ''}
          ${lib.optionalString (cfg.azureAuthentication != null) ''
            export AZURE_CLIENT_SECRET="$(head -n1 ${lib.escapeShellArg cfg.azureAuthentication.clientSecretFile})"
          ''}
          ${lib.optionalString (cfg.oidcAuthentication != null) ''
            export OIDC_CLIENT_SECRET="$(head -n1 ${lib.escapeShellArg cfg.oidcAuthentication.clientSecretFile})"
            export OIDC_CLIENT_ID="$(cat ${config.sops.secrets."docs/clientId".path})"
          ''}
          ${lib.optionalString (cfg.sslKeyFile != null) ''
            export SSL_KEY="$(head -n1 ${lib.escapeShellArg cfg.sslKeyFile})"
          ''}
          ${lib.optionalString (cfg.sslCertFile != null) ''
            export SSL_CERT="$(head -n1 ${lib.escapeShellArg cfg.sslCertFile})"
          ''}
          ${lib.optionalString (cfg.slackIntegration != null) ''
            export SLACK_VERIFICATION_TOKEN="$(head -n1 ${lib.escapeShellArg cfg.slackIntegration.verificationTokenFile})"
          ''}
          ${lib.optionalString (cfg.smtp != null) ''
            export SMTP_PASSWORD="$(head -n1 ${lib.escapeShellArg cfg.smtp.passwordFile})"
          ''}

          ${
            if (cfg.databaseUrl == "local") then
              ''
                export DATABASE_URL=${lib.escapeShellArg localPostgresqlUrl}
                export PGSSLMODE=disable
              ''
            else
              ''
                export DATABASE_URL=${lib.escapeShellArg cfg.databaseUrl}
              ''
          }

          ${cfg.package}/bin/outline-server
        '';
  };
  # systemd.services.outline = {
  #   serviceConfig = {
  #     # Load the client ID from the sops secret file
  #     ExecStartPre = let
  #       script = pkgs.writeShellScript "outline-set-oauth" ''
  #         CLIENT_ID=$(cat ${config.sops.secrets."docs/clientId".path})
  #         # Export as environment variable that Outline will use
  #         echo "OIDC_CLIENT_ID=$CLIENT_ID" >> $RUNTIME_DIRECTORY/env
  #       '';
  #     in "+${script}";
  #
  #     # Load the environment file
  #     EnvironmentFile = "-/run/outline/env";
  #   };
  #
  #   # Ensure sops secrets are available before starting
  #   after = [ "sops-nix.service" ];
  #   wants = [ "sops-nix.service" ];
  # };
}
