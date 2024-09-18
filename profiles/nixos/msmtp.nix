{
  self,
  config,
  pkgs,
  ...
}:

{
  age.secrets.mailPiusPassword = {
    file = "${self}/secrets/mailPiusPassword.age";
    mode = "444";
  };

  programs.msmtp = {
    enable = true;
    setSendmail = true;

    defaults = {
      port = 587;
      tls = true;
    };

    # TODO move host-specific to host
    accounts.default = {
      auth = true;
      aliases = "/etc/aliases";
      user = "pius@vaz.ovh";
      from = "pius <pius@vaz.ovh>";
      host = "mail.vaz.one";
      passwordeval = "${pkgs.coreutils}/bin/cat ${config.age.secrets.mailPiusPassword.path}";
    };
  };

  #Aliases to receive root mail
  environment.etc."aliases" = {
    mode = "0644";
    text = ''
      root: pius@vaz.ovh
      nextcloud: pius@vaz.ovh
    '';
  };
}
