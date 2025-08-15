{
  terraform = {
    required_providers = {
      pocketid = {
        source = "trozz/pocketid";
      };
    };
  };
  provider.pocketid = {
    base_url = "https://auth.koon.us";
    api_token = "\${var.pocketid_api_token}";
  };

  variable.pocketid_api_token = {
    type = "string";
    sensitive = true;
    description = "PocketID API token";
  };

  resource.pocketid_client.photos = {
    name = "Photos";
    callback_urls = [
      "https://photos.koon.us/auth/login"
      "https://photos.koon.us/user-settings"
      "app.immich:///oauth-callback"
    ];
    is_public = false;
    pkce_enabled = false;
  };

  resource.pocketid_client.git = {
    name = "Git";
    callback_urls = [
      "https://git.koon.us/user/oauth2/KoonFamily/callback"
    ];
    is_public = false;
    pkce_enabled = false;
  };

  resource.pocketid_client.docs = {
    name = "Docs";
    callback_urls = [
      "https://docs.koon.us/*"
    ];
    is_public = false;
    pkce_enabled = false;
  };

  output = {
    photos_client_id = {
      value = "\${pocketid_client.photos.id}";
    };
    
    photos_client_secret = {
      value = "\${pocketid_client.photos.client_secret}";
      sensitive = true;
    };

    git_client_id = {
      value = "\${pocketid_client.git.id}";
    };

    git_client_secret = {
      value = "\${pocketid_client.git.client_secret}";
      sensitive = true;
    };

    docs_client_id = {
      value = "\${pocketid_client.docs.id}";
    };

    docs_client_secret = {
      value = "\${pocketid_client.docs.client_secret}";
      sensitive = true;
    };
  };

  resource.local_file.oauth_config = {
    filename = "\${path.module}/../secrets/sops/oauth.yaml";
    content = ''
      photos:
        clientId: ''${pocketid_client.photos.id}
        clientSecret: ''${pocketid_client.photos.client_secret}
      git:
        clientId: ''${pocketid_client.git.id}
        clientSecret: ''${pocketid_client.git.client_secret}
      docs:
        clientId: ''${pocketid_client.docs.id}
        clientSecret: ''${pocketid_client.docs.client_secret}
    '';
    file_permission = "0600";
  };
}
