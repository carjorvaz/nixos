{
  self,
  config,
  pkgs,
  ...
}:

{
  age.secrets.mailAureliusPassword = {
    file = "${self}/secrets/mailAureliusPassword.age";
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
      user = "aurelius@vaz.ovh";
      from = "aurelius <aurelius@vaz.ovh>";
      host = "mail.vaz.one";
      passwordeval = "${pkgs.coreutils}/bin/cat ${config.age.secrets.mailAureliusPassword.path}";
    };
  };

  #Aliases to receive root mail
  environment.etc."aliases" = {
    mode = "0644";
    text = ''
      root: aurelius@vaz.ovh
      nextcloud: aurelius@vaz.ovh
    '';
  };
}
