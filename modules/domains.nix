{ ... }:
{
  config.ark.domains = [
    {
      provider = "cloudflare";
      domain = "koon.us";
      role = "main";
    }
    {
      provider = "porkbun";
      domain = "redactedaddress.com";
      role = "secondary";
    }
  ];
}
