{
  self,
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "lisp.vaz.one";
  corpusRoot = "/persist/lisp-corpus";
  archiveName = "lisp-corpus.zip";
  archiveCacheDir = "/var/cache/lisp-corpus-share";
  archivePath = "${archiveCacheDir}/${archiveName}";
  htpasswdFile = config.age.secrets.lispCorpusShareHtpasswd.path;

  # Hadrianus is the only public ingress for this corpus. Keep pius's backend
  # listener reachable only from that Tailscale peer.
  hadrianusTailscaleIPv4 = "100.103.78.39";

  shareIndex = pkgs.writeTextDir "index.html" ''
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Lisp corpus</title>
        <style>
          :root {
            color-scheme: light dark;
            font-family: system-ui, sans-serif;
          }

          body {
            max-width: 42rem;
            margin: 3rem auto;
            padding: 0 1rem;
            line-height: 1.5;
          }

          h1 {
            letter-spacing: 0;
          }

          nav {
            display: flex;
            flex-wrap: wrap;
            gap: 0.75rem;
          }

          nav a {
            border: 1px solid currentColor;
            border-radius: 6px;
            padding: 0.65rem 0.85rem;
            color: inherit;
            text-decoration: none;
          }
        </style>
      </head>
      <body>
        <main>
          <h1>Lisp corpus</h1>
          <nav aria-label="Corpus actions">
            <a href="/${archiveName}">Download everything</a>
            <a href="/browse/">Browse files</a>
            <a href="/${archiveName}.sha256">SHA-256</a>
          </nav>
          <p>The archive refreshes automatically. Existing direct file links remain available at their original paths.</p>
        </main>
      </body>
    </html>
  '';

  refreshArchive = pkgs.writeShellApplication {
    name = "lisp-corpus-refresh-archive";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
      zip
    ];
    text = ''
      cache_dir=${lib.escapeShellArg archiveCacheDir}
      corpus_root=${lib.escapeShellArg corpusRoot}
      archive_name=${lib.escapeShellArg archiveName}
      archive="$cache_dir/$archive_name"
      lock="$cache_dir/.refresh.lock"

      mkdir -p "$cache_dir"

      (
        flock -n 9 || {
          echo "Archive refresh already running"
          exit 0
        }

        tmp="$(mktemp "$cache_dir/.$archive_name.XXXXXX")"
        trap 'rm -f "$tmp"' EXIT
        rm -f "$tmp"

        (
          cd "$corpus_root" || exit
          zip -9 -q -r "$tmp" . -x './.zfs/*'
        )

        chmod 0644 "$tmp"
        mv -f "$tmp" "$archive"

        (
          cd "$cache_dir" || exit
          sha256sum "$archive_name" > "$archive_name.sha256.tmp"
          chmod 0644 "$archive_name.sha256.tmp"
          mv -f "$archive_name.sha256.tmp" "$archive_name.sha256"
        )
      ) 9>"$lock"
    '';
  };

  privateReadOnlyConfig = ''
    limit_except GET {
      deny all;
    }

    allow ${hadrianusTailscaleIPv4};
    deny all;
  '';

  corpusAutoindexConfig = ''
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    charset utf-8;
  '';
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

    locations."= /" = {
      return = "302 /index.html";
      extraConfig = privateReadOnlyConfig;
    };

    locations."= /index.html" = {
      alias = "${shareIndex}/index.html";
      extraConfig = privateReadOnlyConfig + ''
        default_type text/html;
      '';
    };

    locations."= /${archiveName}" = {
      alias = archivePath;
      extraConfig = privateReadOnlyConfig + ''
        default_type application/zip;
      '';
    };

    locations."= /${archiveName}.sha256" = {
      alias = "${archivePath}.sha256";
      extraConfig = privateReadOnlyConfig + ''
        default_type text/plain;
      '';
    };

    locations."/browse/" = {
      alias = "${corpusRoot}/";
      extraConfig =
        privateReadOnlyConfig
        + ''
          disable_symlinks on from=${corpusRoot};
        ''
        + corpusAutoindexConfig;
    };

    locations."/" = {
      root = corpusRoot;
      tryFiles = "$uri $uri/ =404";
      extraConfig =
        privateReadOnlyConfig
        + ''
          disable_symlinks on from=$document_root;
        ''
        + corpusAutoindexConfig;
    };
  };

  systemd.tmpfiles.rules = [
    "d ${archiveCacheDir} 0755 root root -"
  ];

  systemd.services.lisp-corpus-share-archive = {
    description = "Build downloadable Lisp corpus archive";
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe refreshArchive;
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      UMask = "0022";
    };
  };

  systemd.timers.lisp-corpus-share-archive = {
    description = "Refresh downloadable Lisp corpus archive";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
