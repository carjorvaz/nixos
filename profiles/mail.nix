{ config, inputs, lib, pkgs, ... }:

{
  imports = [
    inputs.simple-nixos-mailserver.nixosModule {
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
            hashedPasswordFile = "/persist/secrets/mail/carlos_hashed_password";
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
              "/persist/secrets/mail/mafalda_hashed_password";
            aliases = [ "@mafaldaribeiro.com" "@mafaldaribeiro.pt" ];
          };
        };

        # Use Let's Encrypt certificates. Note that this needs to set up a stripped
        # down nginx and opens port 80.
        certificateScheme = 3;
      };
    }
  ];
}
