{ ... }:
{
  den.aspects.hcloud-provider = {
    terranix = {
      terraform.required_providers.hcloud = {
        source = "hetznercloud/hcloud";
        version = "~> 1.45";
      };

      variable.hcloud_token = {
        type = "string";
        sensitive = true;
      };

      provider.hcloud.token = "\${var.hcloud_token}";
    };
  };

  den.aspects.porkbun-provider = {
    terranix = {
      terraform.required_providers.porkbun = {
        source = "jianyuan/porkbun";
        version = "~> 0.2.3";
      };

      variable.porkbun_api_key = {
        type = "string";
        sensitive = true;
      };
      variable.porkbun_secret_key = {
        type = "string";
        sensitive = true;
      };

      provider.porkbun = {
        api_key    = "\${var.porkbun_api_key}";
        secret_key = "\${var.porkbun_secret_key}";
      };
    };
  };
}
