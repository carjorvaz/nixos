{ pkgs, ... }:

let
  domain = "firecrawl.vaz.ovh";
in
{
  services.firecrawl = {
    enable = true;
    package = pkgs.firecrawl;
    publicUrl = domain;

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
