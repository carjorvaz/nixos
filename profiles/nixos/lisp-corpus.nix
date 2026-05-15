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
  archiveCacheDir = "/persist/var/cache/lisp-corpus-share";
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
        <link rel="stylesheet" href="/share.css">
      </head>
      <body>
        <main>
          <p class="eyebrow">Private share</p>
          <h1>Lisp corpus</h1>
          <p class="lede">Browse the corpus directly or download the current ZIP archive in one file.</p>
          <nav aria-label="Corpus actions">
            <a class="primary" href="/${archiveName}">Download ZIP</a>
            <a href="/browse/">Browse files</a>
            <a href="/${archiveName}.sha256">SHA-256</a>
          </nav>
          <p class="meta">Current archive: ${archiveName}. Refreshed weekly.</p>
        </main>
      </body>
    </html>
  '';

  shareCss = pkgs.writeTextDir "share.css" ''
    :root {
      color-scheme: light dark;
      background: #f7f7f8;
      color: #181a1b;
      accent-color: #1d6f8f;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    * {
      box-sizing: border-box;
    }

    body {
      min-height: 100vh;
      margin: 0;
      display: grid;
      align-items: center;
      padding: 2rem;
    }

    main {
      width: min(100%, 46rem);
      margin: 0 auto;
      padding-top: 1.5rem;
      border-top: 4px solid #1d6f8f;
    }

    .eyebrow {
      margin: 0 0 0.75rem;
      color: #1d6f8f;
      font-weight: 700;
    }

    h1 {
      margin: 0;
      font-size: clamp(2.5rem, 10vw, 4.5rem);
      line-height: 1;
      letter-spacing: 0;
    }

    .lede {
      max-width: 34rem;
      margin: 1rem 0 2rem;
      color: #555d63;
      font-size: 1.1rem;
      line-height: 1.6;
    }

    nav {
      display: flex;
      flex-wrap: wrap;
      gap: 0.75rem;
    }

    nav a {
      min-height: 3rem;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      border: 1px solid #b7c2c9;
      border-radius: 6px;
      padding: 0.75rem 1rem;
      color: inherit;
      background: #ffffff;
      font-weight: 650;
      text-decoration: none;
    }

    nav a.primary {
      border-color: #1d6f8f;
      background: #1d6f8f;
      color: #ffffff;
    }

    .meta {
      margin-top: 2rem;
      color: #666f75;
      font-size: 0.9rem;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        background: #151719;
        color: #f7f7f8;
      }

      main {
        border-top-color: #65c6e8;
      }

      .eyebrow {
        color: #65c6e8;
      }

      .lede,
      .meta {
        color: #b7c2c9;
      }

      nav a {
        border-color: #46535b;
        background: #202529;
      }

      nav a.primary {
        border-color: #65c6e8;
        background: #65c6e8;
        color: #111416;
      }
    }
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
      corpus_parent="$(dirname "$corpus_root")"
      corpus_basename="$(basename "$corpus_root")"
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
          cd "$corpus_parent" || exit
          zip -6 -q -r -y "$tmp" "$corpus_basename" -x "$corpus_basename/.zfs/*"
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
      add_header Cache-Control "private, no-store" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header Referrer-Policy "no-referrer" always;
      add_header Content-Security-Policy "default-src 'self'; object-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'" always;
      add_header Cross-Origin-Resource-Policy "same-origin" always;
    '';

    locations."= /" = {
      root = shareIndex;
      tryFiles = "/index.html =404";
      extraConfig = privateReadOnlyConfig + ''
        default_type text/html;
      '';
    };

    locations."= /index.html" = {
      alias = "${shareIndex}/index.html";
      extraConfig = privateReadOnlyConfig + ''
        default_type text/html;
      '';
    };

    locations."= /share.css" = {
      alias = "${shareCss}/share.css";
      extraConfig = privateReadOnlyConfig + ''
        default_type text/css;
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
    "d /persist/var/cache 0755 root root -"
    "d ${archiveCacheDir} 0755 root root -"
  ];

  systemd.services.lisp-corpus-share-archive = {
    description = "Build downloadable Lisp corpus archive";
    after = [ "local-fs.target" ];
    unitConfig.ConditionPathIsDirectory = corpusRoot;
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
      OnCalendar = "Sun *-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "2h";
    };
  };
}
