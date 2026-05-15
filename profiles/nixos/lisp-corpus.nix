{ self, config, ... }:

let
  domain = "lisp.vaz.one";
  corpusRoot = "/persist/lisp-corpus";
  htpasswdFile = config.age.secrets.lispCorpusShareHtpasswd.path;

  # Hadrianus is the only public ingress for this corpus. Keep pius's backend
  # listener reachable only from that Tailscale peer.
  hadrianusTailscaleIPv4 = "100.103.78.39";
in
{
  age.secrets = {
    lispCorpusShareHtpasswd = {
      file = "${self}/secrets/lispCorpusShareHtpasswd.age";
      owner = "root";
      group = "nginx";
      mode = "0440";
    };

    lispCorpusSharePassword = {
      file = "${self}/secrets/lispCorpusSharePassword.age";
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  services.sanoid = {
    templates.lispCorpus = {
      frequently = 0;
      hourly = 24;
      daily = 14;
      weekly = 8;
      monthly = 12;
      yearly = 2;
      autosnap = true;
      autoprune = true;
    };

    datasets."zsafe/lisp-corpus" = {
      use_template = [ "lispCorpus" ];
    };
  };

  services.nginx.virtualHosts.${domain} = {
    root = corpusRoot;
    basicAuthFile = htpasswdFile;

    extraConfig = ''
      server_tokens off;
      add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
      add_header Cache-Control "private" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header Referrer-Policy "no-referrer" always;
      add_header Content-Security-Policy "default-src 'self'; object-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'" always;
      add_header Cross-Origin-Resource-Policy "same-origin" always;
    '';

    locations."/" = {
      root = corpusRoot;
      tryFiles = "$uri $uri/ =404";
      extraConfig = ''
        limit_except GET {
          deny all;
        }

        allow ${hadrianusTailscaleIPv4};
        deny all;

        disable_symlinks on from=$document_root;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        charset utf-8;
      '';
    };
  };
}
