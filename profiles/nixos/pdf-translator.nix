{ self, config, ... }:

{
  age.secrets.deepseek-api-key.file = "${self}/secrets/deepseek-api-key.age";

  services.pdf-translator = {
    enable = true;
    apiBase = "https://api.deepseek.com/v1";
    apiKeyFile = config.age.secrets.deepseek-api-key.path;
    model = "deepseek-chat";
  };

  services.nginx.virtualHosts."pdf-translator.vaz.ovh" = {
    forceSSL = true;
    useACMEHost = "vaz.ovh";
    locations."/".proxyPass = "http://127.0.0.1:${toString config.services.pdf-translator.port}";
  };
}
