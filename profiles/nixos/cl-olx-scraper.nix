{ self, config, ... }:

{
  age.secrets.cl-olx-scraper-config.file = "${self}/secrets/cl-olx-scraper-config.age";

  services.cl-olx-scraper = {
    enable = true;
    configFile = config.age.secrets.cl-olx-scraper-config.path;
    interval = "5min";
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/cl-olx-scraper";
      mode = "0700";
    }
  ];
}
