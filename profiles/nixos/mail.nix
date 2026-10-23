{
  self,
  config,
  inputs,
  lib,
  ...
}:

let
  rspamdLocalRules = builtins.toFile "mail-rspamd-local.lua" ''
    local function has_all(task, symbols)
      for _, symbol in ipairs(symbols) do
        if not task:has_symbol(symbol) then
          return false
        end
      end

      return true
    end

    local function has_any(task, symbols)
      for _, symbol in ipairs(symbols) do
        if task:has_symbol(symbol) then
          return true
        end
      end

      return false
    end

    local abused_google_groups_domains = {
      ['13083977115.com'] = true,
      ['bwty-sports.com'] = true,
      ['chinacvcn.com'] = true,
      ['youejia8.com'] = true,
      ['yuanzhevip.com'] = true,
      ['zjgk895.com'] = true,
    }

    local function header_contains_any_domain(task, header_name, domains)
      local value = task:get_header(header_name)
      if not value then
        return false
      end

      if type(value) == 'table' then
        value = table.concat(value, '\n')
      end

      value = string.lower(tostring(value))

      for domain, _ in pairs(domains) do
        if value:find(domain, 1, true) then
          return true
        end
      end

      return false
    end

    local function register_rule(name, score, description, callback)
      rspamd_config:register_symbol({
        name = name,
        type = 'postfilter',
        score = score,
        group = 'local',
        description = description,
        callback = callback,
      })
    end

    register_rule(
      'LOCAL_UNAUTH_HTML_DIRECT',
      5.0,
      'HTML mail with no SPF, DKIM, or DMARC arriving directly at the MX',
      function(task)
        return has_all(task, {
          'AUTH_NA',
          'R_SPF_NA',
          'R_DKIM_NA',
          'DMARC_NA',
          'MIME_HTML_ONLY',
        }) and has_any(task, {
          'ONCE_RECEIVED',
          'RCVD_COUNT_ZERO',
        })
      end
    )

    register_rule(
      'LOCAL_AUTHENTICATED_FUZZY_HAM_HINT',
      -5.0,
      'Reduce false positives from fuzzy matches on fully authenticated mail',
      function(task)
        return has_all(task, {
          'FUZZY_DENIED',
          'R_SPF_ALLOW',
          'R_DKIM_ALLOW',
          'DMARC_POLICY_ALLOW',
        })
      end
    )

    register_rule(
      'LOCAL_AUTHENTICATED_LIST_HAM_HINT',
      -4.0,
      'Reduce false positives from authenticated list mail hit by abuse URL reputation',
      function(task)
        return has_all(task, {
          'ABUSE_SURBL',
          'R_SPF_ALLOW',
          'R_DKIM_ALLOW',
          'DMARC_POLICY_ALLOW',
          'HAS_LIST_UNSUB',
        })
      end
    )

    register_rule(
      'LOCAL_ABUSED_GOOGLE_GROUPS_LIST',
      8.0,
      'Known abused Google Groups/list domains seen in catchall spam',
      function(task)
        return task:has_symbol('MAILLIST') and (
          header_contains_any_domain(task, 'List-ID', abused_google_groups_domains)
          or header_contains_any_domain(task, 'X-BeenThere', abused_google_groups_domains)
          or header_contains_any_domain(task, 'Mailing-list', abused_google_groups_domains)
        )
      end
    )
  '';
in
{
  age.secrets = {
    mailCarlosHashedPassword.file = "${self}/secrets/mailCarlosHashedPassword.age";
    mailMafaldaHashedPassword.file = "${self}/secrets/mailMafaldaHashedPassword.age";
    mailPiusHashedPassword.file = "${self}/secrets/mailPiusHashedPassword.age";
  };

  imports = [
    inputs.simple-nixos-mailserver.nixosModule
    {
      mailserver = {
        enable = true;
        fqdn = "mail.vaz.one";

        domains = [
          "vaz.one"
          "vaz.ovh"
          "carjorvaz.com"
          "carlosvaz.com"
          "carlosvaz.net"
          "carlosvaz.pt"
          "cjv.pt"
          "sucklessweb.com"
          "tobepractical.com"

          "mafaldaribeiro.com"
          "mafaldaribeiro.pt"
        ];

        # A list of all login accounts. To create the password hashes, use
        # nix run nixpkgs.apacheHttpd -c htpasswd -nbB "" "super secret password" | cut -d: -f2 > /hashed/password/file/location
        accounts = {
          "carlos@vaz.one" = {
            hashedPasswordFile = config.age.secrets.mailCarlosHashedPassword.path;

            # aliases = [ "postmaster@example.com" ];
            # Aliases starting with @ are catchall aliases
            aliases = [
              "@vaz.one"
              "@vaz.ovh"
              "@carjorvaz.com"
              "@carlosvaz.com"
              "@carlosvaz.net"
              "@carlosvaz.pt"
              "@cjv.pt"
              "@sucklessweb.com"
              "@tobepractical.com"
            ];
          };

          "me@mafaldaribeiro.com" = {
            hashedPasswordFile = config.age.secrets.mailMafaldaHashedPassword.path;

            aliases = [
              "@mafaldaribeiro.com"
              "@mafaldaribeiro.pt"
            ];
          };

          "pius@carjorvaz.com" = {
            hashedPasswordFile = config.age.secrets.mailPiusHashedPassword.path;
          };
        };

        # Use the wildcard vaz.one certificate managed by the shared DNS-01
        # ACME profile imported by hadrianus.
        x509.useACMEHost = "vaz.one";

        # https://nixos-mailserver.readthedocs.io/en/latest/migrations.html
        stateVersion = 3;
      };
    }
  ];

  # DNSBLs (Spamhaus ZEN/DBL, DNSWL) refuse or rate-limit queries coming from
  # public resolvers such as blocky's DoQ upstreams, silently disabling the
  # blocklist layer. Give rspamd its own resolver that performs real recursion,
  # bound to a spare loopback address so it does not clash with blocky on
  # 127.0.0.1.
  services = {
    rspamd = {
      localLuaRules = rspamdLocalRules;
      locals = {
        "options.inc".text = ''
          dns {
            # 127.0.0.4 is the local unbound instance (real recursion). DNSBLs
            # such as Spamhaus ZEN/DBL and DNSWL refuse or rate-limit queries
            # relayed through public resolvers like blocky's DoQ upstreams, so
            # rspamd must not resolve through blocky.
            nameserver = ["127.0.0.4"];
          }
        '';
        "classifier-bayes.conf".text = lib.mkAfter ''
          autolearn {
            # 8 keeps autolearn reachable: most spam lands between add_header (6)
            # and reject (15), and with the default 12 almost nothing qualified.
            spam_threshold = 8.0;
            junk_threshold = 10.0;
            ham_threshold = -2.0;
            check_balance = true;
            min_balance = 0.6;
          }
        '';
        "rbl.conf".text = ''
          rbls {
            senderscore_reputation {
              disable_monitoring = true;
            }
          }
        '';
      };
    };
    kresd.enable = lib.mkForce false;
    unbound = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        server = {
          interface = [ "127.0.0.4" ];
          access-control = [ "127.0.0.0/8 allow" ];
          prefetch = true;
          hide-identity = true;
          hide-version = true;
        };
      };
    };
  };

  systemd.services.rspamd = {
    after = [
      "blocky.service"
      "unbound.service"
    ];
    wants = [
      "blocky.service"
      "unbound.service"
    ];
    # Do not give up while the Required redis instance is coming back.
    startLimitIntervalSec = 0;
    serviceConfig = {
      OOMScoreAdjust = -800;
      RestartSec = "2s";
    };
  };

  # simple-nixos-mailserver leaves redis-rspamd at Restart=no. One OOM kill
  # then stops rspamd (Requires) and postfix (Requires), and mail stays down
  # until someone notices.
  systemd.services.redis-rspamd.serviceConfig = {
    Restart = "always";
    RestartSec = "2s";
    OOMScoreAdjust = -800;
  };

  systemd.services.postfix = {
    # rspamd is Required by postfix, so a dead rspamd stops postfix. Pull
    # postfix back up whenever rspamd starts again.
    wantedBy = [
      "multi-user.target"
      "rspamd.service"
    ];
    serviceConfig.OOMScoreAdjust = -800;
  };

  systemd.services.dovecot.serviceConfig.OOMScoreAdjust = -800;

  environment.persistence."/persist".directories = [
    "/var/lib/rspamd"
    "/var/lib/unbound"
    # Rspamd Bayes/stat data is stored in the local Redis instance.
    "/var/lib/redis-rspamd"
    {
      directory = "/var/vmail";
      user = "virtualMail";
      group = "virtualMail";
    }
    {
      directory = "/var/dkim";
      user = "opendkim";
      group = "opendkim";
    }
  ];
}
