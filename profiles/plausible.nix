{ self, config, lib, pkgs, ... }:

# STATE:
# - Reset admin user password, it doesn't seem to use the one provided in the configuration.
# - Add the website to Plausible, add the snippet to the website.
# - Enable all email alerts.
# - Enable Google Search Console integration as explained here: https://plausible.io/docs/self-hosting-configuration#google-api-integration
let domain = "plausible.vaz.one";
in {
  age.secrets = {
    plausibleAdminPassword.file = "${self}/secrets/plausibleAdminPassword.age";
    plausibleReleaseCookie.file = "${self}/secrets/plausibleReleaseCookie.age";
    plausibleSecretKeybase.file = "${self}/secrets/plausibleSecretKeybase.age";
  };

  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      enableACME = true;
      locations."/".proxyPass =
        "http://127.0.0.1:${toString config.services.plausible.server.port}";
    };

    plausible = {
      enable = true;
      releaseCookiePath = config.age.secrets.plausibleSecretKeybase.path;

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
        secretKeybaseFile = config.age.secrets.plausibleSecretKeybase.path;
      };
    };
  };

  environment.persistence."/persist".directories =
    [ "/var/lib/private/plausible" "/var/lib/postgresql" ];
}
