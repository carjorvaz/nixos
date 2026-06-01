_:

let
  domain = "ultimate-tic-tac-toe.carjorvaz.com";
  oldDomain = "uttt.vaz.one";
  port = 4242;
  stateDirectory = "ultimate-tic-tac-toe";
  stateDir = "/var/lib/${stateDirectory}";
in
{
  services.ultimate-tic-tac-toe = {
    enable = true;
    inherit port stateDirectory;
  };

  services.nginx.virtualHosts.${domain} = {
    forceSSL = true;
    enableACME = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
    };
  };

  services.nginx.virtualHosts.${oldDomain} = {
    forceSSL = true;
    useACMEHost = "vaz.one";
    globalRedirect = domain;
  };

  environment.persistence."/persist".directories = [
    {
      directory = stateDir;
      user = "ultimate-tic-tac-toe";
      group = "ultimate-tic-tac-toe";
      mode = "0700";
    }
  ];
}
