{
  config,
  lib,
  pkgs,
  ...
}:

{
  security.acme = {
    acceptTerms = true;
    defaults.email = "carlos+letsencrypt@vaz.one";
  };

  environment.persistence."/persist".directories = [ "/var/lib/acme" ];
}
