{
  self,
  config,
  ...
}:
{
  age.secrets.telegramMirrorEnv = {
    file = "${self}/secrets/telegramMirrorEnv.age";
    owner = "telegram-mirror";
    group = "telegram-mirror";
    mode = "0400";
  };

  services.telegram-mirror = {
    enable = true;
    environmentFile = config.age.secrets.telegramMirrorEnv.path;
    archiveDir = "/persist/telegram-mirror/archive";
  };

  systemd.tmpfiles.rules = [
    "d /persist/telegram-mirror 0700 telegram-mirror telegram-mirror -"
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/telegram-mirror";
      user = "telegram-mirror";
      group = "telegram-mirror";
      mode = "0700";
    }
  ];
}
