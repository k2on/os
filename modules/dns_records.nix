{ config, ... }:
{
  den.aspects.ark = {
    dns_records = [
      {
        domain = config.ark.mainDomain;
        name = "industries";
        type = "TXT";
        content = "apple-domain-verification=NUm30sbwUStoV2MD";
      }
    ];
  };
}
