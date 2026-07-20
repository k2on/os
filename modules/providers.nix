{ ... }:
{
  den.aspects.hcloud-provider = {
    terranix = {
      terraform.required_providers.hcloud = {
        source = "hetznercloud/hcloud";
        version = "~> 1.45";
      };

      provider.hcloud = {};
    };
  };

  den.aspects.porkbun-provider = {
    terranix = {
      terraform.required_providers.porkbun = {
        source = "cullenmcdermott/porkbun";
        version = "~> 0.3.0";
      };
      provider.porkbun = {};
    };
  };

  den.aspects.cloudflare-provider = {
    terranix = {
      terraform.required_providers.cloudflare = {
        source = "cloudflare/cloudflare";
        version = "~> 5.22.0";
      };
      provider.cloudflare = {};
    };
  };
}
