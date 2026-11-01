_:

{
  # Edge jails for the public mail/web host. The base sshd jail and global
  # bantime/ignoreIP/persistence live in profiles/nixos/server.nix.
  services.fail2ban.jails = {
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
    # line is "host nginx[pid]: <access line>" and the date is supplied
    # separately, so the shipped regexes match nothing. These two custom
    # filters allow the journal prefix and are scoped to scanner 404/400s.
    nginx-404-probe = {
      filter.Definition = {
        failregex = ''^\s*(?:(?!\[)\S+ nginx\[\d+\]: )?<HOST> - \S+ \[[^\]]*\] "(?:GET|POST|HEAD) [^"]*(?:/\.env|/\.git|/\.aws|/wp-config\.php|/xmlrpc\.php|/vendor/phpunit|/server-status|/wp-login\.php|/wp-admin\.php|/wp-signup\.php|/phpmyadmin|/pma/|/myadmin|/cgi-bin/|/mysqladmin/|/(?:wp|wordpress|wp-json|site|news|cms|press)/)[^"]*" 404'';
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

    nginx-bad-request-journal = {
      filter.Definition = {
        failregex = ''^\s*(?:(?!\[)\S+ nginx\[\d+\]: )?<HOST> - \S+ \[[^\]]*\] "[^"]*" 400'';
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
}
