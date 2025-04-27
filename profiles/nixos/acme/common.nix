{ ... }:

{
  security.acme = {
    acceptTerms = true;
    defaults.email = "letsencrypt@carjorvaz.com";
  };

  environment.persistence."/persist".directories = [ "/var/lib/acme" ];
}
