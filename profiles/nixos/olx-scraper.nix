{ self, config, ... }:

{
  age.secrets.olx-scraper-config.file = "${self}/secrets/olx-scraper-config.age";

  services.olx-scraper = {
    enable = true;
    configFile = config.age.secrets.olx-scraper-config.path;
    interval = "5min";
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/olx-scraper";
      mode = "0700";
    }
  ];
}
