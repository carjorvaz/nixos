{
  self,
  config,
  inputs,
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

    local function register_rule(name, score, description, dependencies, callback)
      rspamd_config:register_symbol({
        name = name,
        score = score,
        group = 'local',
        description = description,
        callback = callback,
      })

      for _, dependency in ipairs(dependencies) do
        rspamd_config:register_dependency(name, dependency)
      end
    end

    register_rule(
      'LOCAL_UNAUTH_HTML_DIRECT',
      5.0,
      'HTML mail with no SPF, DKIM, or DMARC arriving directly at the MX',
      {
        'AUTH_NA',
        'R_SPF_NA',
        'R_DKIM_NA',
        'DMARC_CALLBACK',
        'MIME_HTML_ONLY',
        'ONCE_RECEIVED',
        'RCVD_COUNT_ZERO',
      },
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
      {
        'FUZZY_DENIED',
        'R_SPF_ALLOW',
        'R_DKIM_ALLOW',
        'DMARC_CALLBACK',
      },
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
      {
        'ABUSE_SURBL',
        'R_SPF_ALLOW',
        'R_DKIM_ALLOW',
        'DMARC_CALLBACK',
        'HAS_LIST_UNSUB',
      },
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
  '';
in
{
  age.secrets.mailCarlosHashedPassword.file = "${self}/secrets/mailCarlosHashedPassword.age";
  age.secrets.mailMafaldaHashedPassword.file = "${self}/secrets/mailMafaldaHashedPassword.age";
  age.secrets.mailPiusHashedPassword.file = "${self}/secrets/mailPiusHashedPassword.age";

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
        loginAccounts = {
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

        # Use Let's Encrypt certificates. Note that this needs to set up a stripped
        # down nginx and opens port 80.
        certificateScheme = "acme-nginx";

        # https://nixos-mailserver.readthedocs.io/en/latest/migrations.html
        stateVersion = 3;
      };
    }
  ];

  services.rspamd.localLuaRules = rspamdLocalRules;

  environment.persistence."/persist".directories = [
    "/var/lib/rspamd"
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
