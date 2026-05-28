{ pkgs, ... }:

let
  domain = "firecrawl.vaz.ovh";
in
{
  services.firecrawl = {
    enable = true;
    package = pkgs.firecrawl;
    publicUrl = domain;

    # This singleton is private behind nginx + Tailscale auth, so keep
    # Firecrawl's Supabase-style API-key machinery disabled.
    useDbAuthentication = false;

    nginx = {
      enable = true;
      inherit domain;
    };

    homer = {
      enable = true;
      subtitle = "Web extraction";
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/firecrawl";
      user = "firecrawl";
      group = "firecrawl";
      mode = "0700";
    }
    {
      directory = "/var/cache/firecrawl";
      user = "firecrawl";
      group = "firecrawl";
      mode = "0700";
    }
  ];
}
