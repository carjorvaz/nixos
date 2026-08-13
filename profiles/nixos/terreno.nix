# Terreno — private tailnet test instance (cjv + nalves599).
# The app is gated twice: nginx basicAuth (every page) and the app's own
# STAFF_TOKEN guard on /orders + /stl. Same password both layers so the
# browser prompts once.
{
  config,
  self,
  inputs,
  pkgs,
  ...
}:

let
  webHost = "terreno.vaz.ovh";
  terrenoPkg = inputs.strava-trophy-rs.packages.${pkgs.system}.default;
in
{
  imports = [ ./nginx/common.nix ];

  age.secrets = {
    # STAFF_TOKEN=<same password as the htpasswd entries> (+ SMTP_* later).
    terrenoEnv = {
      file = "${self}/secrets/terrenoEnv.age";
      owner = "terreno";
      group = "terreno";
      mode = "0400";
    };
    # cjv:<apr1> / nalves599:<apr1> — one shared site password for the test phase.
    terrenoHtpasswd = {
      file = "${self}/secrets/terrenoHtpasswd.age";
      owner = "root";
      group = "nginx";
      mode = "0440";
    };
  };

  services.terreno = {
    enable = true;
    package = terrenoPkg;
    environmentFile = config.age.secrets.terrenoEnv.path;
    port = 8790; # 8787 is taken by ott-rs on pius
    baseUrl = "https://${webHost}";
  };

  services.nginx.virtualHosts.${webHost} = {
    forceSSL = true;
    useACMEHost = "vaz.ovh"; # wildcard cert covers *.vaz.ovh via OVH DNS-01
    basicAuthFile = config.age.secrets.terrenoHtpasswd.path;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8790";
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

  environment.persistence."/persist".directories = [ "/var/lib/terreno" ];
}
