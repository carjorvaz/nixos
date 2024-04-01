{ config, inputs, ... }:

{
  age.secrets.mailCarlosHashedPassword.file =
    ../../secrets/mailCarlosHashedPassword.age;

  age.secrets.mailMafaldaHashedPassword.file =
    ../../secrets/mailMafaldaHashedPassword.age;

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
            hashedPasswordFile =
              config.age.secrets.mailCarlosHashedPassword.path;

            # aliases = [ "postmaster@example.com" ];
            # Aliases starting with @ are catchall aliases
            aliases = [
              "@vaz.one"
              "@vaz.ovh"
              "@carjorvaz.com"
              "@carlosvaz.net"
              "@carlosvaz.pt"
              "@cjv.pt"
              "@sucklessweb.com"
              "@tobepractical.com"
            ];
          };

          "me@mafaldaribeiro.com" = {
            hashedPasswordFile =
              config.age.secrets.mailMafaldaHashedPassword.path;

            aliases = [ "@mafaldaribeiro.com" "@mafaldaribeiro.pt" ];
          };
        };

        # Use Let's Encrypt certificates. Note that this needs to set up a stripped
        # down nginx and opens port 80.
        certificateScheme = "acme-nginx";
      };
    }
  ];

  environment.persistence."/persist".directories = [
    "/var/lib/rspamd"
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
