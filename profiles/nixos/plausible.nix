{ self, config, ... }:

let
  domain = "plausible.carjorvaz.com";
in
{
  age.secrets = {
    plausibleAdminPassword.file = "${self}/secrets/plausibleAdminPassword.age";
    plausibleSecretKeybase.file = "${self}/secrets/plausibleSecretKeybase.age";

    mailPiusPassword = {
      file = "${self}/secrets/mailPiusPassword.age";
      mode = "444";
    };
  };

  services = {
    plausible = {
      enable = true;

      adminUser = {
        # activate is used to skip the email verification of the admin-user that's
        # automatically created by plausible. This is only supported if
        # postgresql is configured by the module. This is done by default, but
        # can be turned off with services.plausible.database.postgres.setup.
        activate = true;
        email = "plausible@carjorvaz.com";
        passwordFile = config.age.secrets.plausibleAdminPassword.path;
      };

      server = {
        baseUrl = "https://${domain}";
        listenAddress = "100.121.87.116";
        secretKeybaseFile = config.age.secrets.plausibleSecretKeybase.path;
      };

      mail = {
        email = "pius@vaz.ovh";

        smtp = {
          user = "pius@vaz.ovh";
          hostAddr = "mail.vaz.one";
          hostPort = 587;
          passwordFile = config.age.secrets.mailPiusPassword.path;
        };
      };
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/clickhouse";
      mode = "0750";
      user = "clickhouse";
      group = "clickhouse";
    }
    {
      directory = "/var/lib/private/plausible";
      mode = "0750";
      user = "plausible";
      group = "plausible";
    }
    # "/var/lib/postgresql" # Already persisted by nextcloud
  ];
}
