# Terreno — app host (pius). The PUBLIC vhost lives on the bastion
# (hadrianus), which terminates TLS + basicAuth and proxies here over the
# tailnet. The app's own STAFF_TOKEN guard still protects /orders + /stl.
{
  config,
  self,
  inputs,
  pkgs,
  ...
}:

let
  webHost = "terreno.vaz.one";
  terrenoPkg = inputs.strava-trophy-rs.packages.${pkgs.system}.default;
in
{
  age.secrets = {
    # STAFF_TOKEN=<shared site password> (+ SMTP_* later).
    terrenoEnv = {
      file = "${self}/secrets/terrenoEnv.age";
      owner = "terreno";
      group = "terreno";
      mode = "0400";
    };
  };

  services.terreno = {
    enable = true;
    package = terrenoPkg;
    environmentFile = config.age.secrets.terrenoEnv.path;
    port = 8790; # 8787 is taken by ott-rs on pius
    bindAddress = "127.0.0.1"; # reached via the tailnet-entry vhost below
    baseUrl = "https://${webHost}";
  };

  # Tailnet entry: the bastion proxies to pius:80 (ACL-open); this vhost
  # accepts ONLY the bastion, forces the staff identity (the app trusts
  # X-Forwarded-User), and proxies to the loopback app.
  services.nginx.virtualHosts.${webHost} = {
    listen = [
      {
        addr = "0.0.0.0";
        port = 80;
      }
    ];
    locations."/" = {
      proxyPass = "http://127.0.0.1:8790";
      extraConfig = ''
        allow 100.103.78.39; # hadrianus (bastion) tailscale IP
        deny all;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-User "bastion";
        client_max_body_size 10m;
      '';
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/terreno" ];
}
