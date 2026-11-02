{ config, ... }:

{
  # Imported only by the public edge (hadrianus). Servers that are not
  # reachable from the internet do not run fail2ban: their only clients are
  # LAN/tailnet, which are ignored anyway.
  services.fail2ban = {
    enable = true;

    ignoreIP = [
      "10.0.0.0/8" # pius LAN / unlock bridge
      "192.168.0.0/16"
      "100.64.0.0/10" # Tailscale IPv4
      "fd7a:115c:a1e0::/48" # Tailscale IPv6
    ];

    bantime = "24h";
    bantime-increment = {
      enable = true;
      formula = "ban.Time * math.exp(float(ban.Count+1)*banFactor)/math.exp(1*banFactor)";
      maxtime = "168h";
      overalljails = true;
    };

    jails = {
      dovecot.settings = {
        # block IPs which failed to log-in
        # aggressive mode add blocking for aborted connections
        filter = "dovecot[mode=aggressive]";
        maxretry = 3;
      };

      postfix-sasl.settings = {
        enabled = true;
        filter = "postfix[mode=auth]";
        backend = "systemd";
        journalmatch = "_SYSTEMD_UNIT=postfix.service";
        maxretry = 3;
      };

      # Error-log filters from fail2ban 1.1.0 already understand the journal
      # prefix (__prefix_line); http-auth covers basic-auth brute force including
      # the lisp corpus share, limit-req covers the ott_*/lisp limit_req zones.
      nginx-http-auth.settings = {
        enabled = true;
      };

      nginx-limit-req.settings = {
        enabled = true;
        maxretry = 10;
      };

      # Access-log filters in 1.1.0 are file-backend-only: with journald the
      # line is "host null[pid]: host nginx: <access line>" (journald prefix
      # plus nginx's own syslog header) and the date is supplied
      # separately, so the shipped regexes match nothing. These two custom
      # filters allow the journal prefix and are scoped to scanner 404/400s.
      nginx-404-probe = {
        filter.Definition = {
          failregex = ''^\s*(?:\S+ \S+\[\d+\]: )?(?:\S+ nginx: )?<HOST> - \S+ \[[^\]]*\] "(?:GET|POST|HEAD) [^"]*(?:/\.env|/\.git|/\.aws|/wp-config\.php|/xmlrpc\.php|/vendor/phpunit|/server-status|/wp-login\.php|/wp-admin\.php|/wp-signup\.php|/phpmyadmin|/pma/|/myadmin|/cgi-bin/|/mysqladmin/|/(?:wp|wordpress|wp-json|site|news|cms|press)/)[^"]*" 404'';
          journalmatch = "_SYSTEMD_UNIT=nginx.service + _COMM=nginx";
        };
        settings = {
          enabled = true;
          backend = "systemd";
          journalmatch = "_SYSTEMD_UNIT=nginx.service + _COMM=nginx";
          maxretry = 3;
          findtime = "1h";
        };
      };

      nginx-bad-request = {
        filter.Definition = {
          failregex = ''^\s*(?:\S+ \S+\[\d+\]: )?(?:\S+ nginx: )?<HOST> - \S+ \[[^\]]*\] "[^"]*" 400'';
          journalmatch = "_SYSTEMD_UNIT=nginx.service + _COMM=nginx";
        };
        settings = {
          enabled = true;
          backend = "systemd";
          journalmatch = "_SYSTEMD_UNIT=nginx.service + _COMM=nginx";
          maxretry = 10;
        };
      };
    };
  };

  # Keep bans and the increment state across the ZFS root rollback.
  environment.persistence."/persist".directories = [
    "/var/lib/fail2ban"
    "/var/log/fail2ban"
  ];

  # Filter files are not part of the service unit; without this, a filter-only
  # change is installed but the running daemon keeps the old definitions.
  systemd.services.fail2ban.restartTriggers = [ config.environment.etc."fail2ban/filter.d".source ];
}
