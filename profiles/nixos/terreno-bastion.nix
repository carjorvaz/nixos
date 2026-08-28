# Terreno public vhost on the bastion (hadrianus): terminates TLS (existing
# LE *.vaz.one wildcard) + basicAuth, proxies to the app on pius over the
# tailnet (same pattern as cloud.vaz.one -> piusTailscaleIPv4).
{
  config,
  self,
  ...
}:

let
  webHost = "terreno.vaz.one";
  piusTailscaleIPv4 = "100.121.87.116";
in
{
  age.secrets = {
    # cjv / nalves599 (apr1). Same password as the app's STAFF_TOKEN.
    terrenoHtpasswd = {
      file = "${self}/secrets/terrenoHtpasswd.age";
      owner = "root";
      group = "nginx";
      mode = "0440";
    };
  };

  services.nginx.virtualHosts.${webHost} = {
    forceSSL = true;
    useACMEHost = "vaz.one"; # LE wildcard cert already on the bastion
    basicAuthFile = config.age.secrets.terrenoHtpasswd.path;
    locations."/" = {
      proxyPass = "http://${piusTailscaleIPv4}:80"; # pius tailnet-entry vhost
      extraConfig = ''
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # auth_basic consumed the Authorization header; the app's staff guard
        # trusts the forwarded user identity instead.
        proxy_set_header X-Forwarded-User $remote_user;
        client_max_body_size 10m;
      '';
    };
  };
}
