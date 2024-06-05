{
  config,
  lib,
  pkgs,
  ...
}:

{
  services.fail2ban = {
    enable = true;

    maxretry = 5;
    ignoreIP = [
      "192.168.0.0/16"
      "100.64.0.0/10" # Tailscale
    ];

    bantime = "24h";
    bantime-increment = {
      enable = true; # Enable increment of bantime after each violation
      formula = "ban.Time * math.exp(float(ban.Count+1)*banFactor)/math.exp(1*banFactor)";
      # multipliers = "1 2 4 8 16 32 64";
      maxtime = "168h"; # Do not ban for more than 1 week
      overalljails = true; # Calculate the bantime based on all the violations
    };

    jails = {
      dovecot.settings = {
        # block IPs which failed to log-in
        # aggressive mode add blocking for aborted connections
        filter = "dovecot[mode=aggressive]";
        maxretry = 3;
      };

      nextcloud.settings = {
        enabled = true;
        filter = "nextcloud";
        backend = "auto";
        # bantime = 86400;
        # findtime = 43200;
        # logpath = "/var/log/fail2ban/nextcloud.log";
      };
    };
  };

  environment.etc = {
    "fail2ban/filter.d/nextcloud.conf".text = ''
      [Definition]
      _groupsre = (?:(?:,?\s*"\w+":(?:"[^"]+"|\w+))*)
      failregex = ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Login failed:
                  ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Trusted domain error.
      datepattern = ,?\s*"time"\s*:\s*"%%Y-%%m-%%d[T ]%%H:%%M:%%S(%%z)?"
    '';
  };

  environment.persistence."/persist" = {
    directories = [ "/var/log/fail2ban" ];
  };
}
