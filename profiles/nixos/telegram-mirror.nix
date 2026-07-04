{
  config,
  ...
}:
{
  users.users.telegram-mirror.extraGroups = [ "telegram-secrets" ];

  services.telegram-mirror = {
    enable = true;
    environmentFile = config.age.secrets.piusTelegramEnv.path;
    archiveDir = "/persist/telegram-mirror/archive";
    skipMedia = true;
    timer.enable = false;
  };

  systemd.timers.telegram-mirror = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
      Unit = "telegram-mirror.service";
    };
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
