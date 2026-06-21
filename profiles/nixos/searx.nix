{ config, pkgs, ... }:

let
  domain = "searx.vaz.ovh";
  secretFile = "/run/searx-secret";
  searxBaseUrl = "http://127.0.0.1:${toString config.services.searx.settings.server.port}";
  searxHealthScript = pkgs.writeText "searx-health.py" ''
    import collections
    import datetime
    import json
    import os
    import tempfile
    import time
    import urllib.error
    import urllib.parse
    import urllib.request

    BASE_URL = "${searxBaseUrl}"
    STATE_DIR = "/var/lib/searx-health"
    OUTPUT_PATH = "/var/lib/searx-health/health.json"
    TIMEOUT_SECONDS = 20
    QUERY_DELAY_SECONDS = 5
    TOP_DOMAIN_LIMIT = 10

    KEY_ENGINE_DEFAULTS = {
        "brave": False,
        "duckduckgo": True,
        "google": True,
        "startpage": False,
        "mojeek": False,
        "wiby": False,
        "wikipedia": True,
        "github": True,
        "mdn": True,
        "stackoverflow": True,
        "superuser": True,
        "arch linux wiki": True,
        "nixos wiki": True,
    }

    QUERY_CORPUS = (
        {
            "label": "nix_docs",
            "query": "NixOS module options documentation nix.dev",
        },
        {
            "label": "searxng_openwebui_docs",
            "query": "SearXNG Open WebUI searxng_query_url documentation",
        },
        {
            "label": "firecrawl_extraction_docs",
            "query": "Firecrawl extract API markdown documentation",
        },
    )


    def utc_now():
        return (
            datetime.datetime.now(datetime.timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z")
        )


    def sanitized_error(exc):
        if isinstance(exc, urllib.error.HTTPError):
            return "HTTPError:%s" % exc.code
        if isinstance(exc, urllib.error.URLError):
            if isinstance(getattr(exc, "reason", None), TimeoutError):
                return "TimeoutError"
            return exc.__class__.__name__
        return exc.__class__.__name__


    def fetch_json(path, params=None):
        url = BASE_URL + path
        if params:
            url = url + "?" + urllib.parse.urlencode(params)

        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                body = response.read(1_000_000)
                charset = response.headers.get_content_charset() or "utf-8"
            elapsed = round(time.monotonic() - started, 3)
            return json.loads(body.decode(charset)), elapsed, None
        except Exception as exc:
            elapsed = round(time.monotonic() - started, 3)
            return None, elapsed, sanitized_error(exc)


    def iter_engine_entries(engines_payload):
        if isinstance(engines_payload, list):
            for entry in engines_payload:
                if isinstance(entry, dict):
                    yield entry.get("name"), entry
        elif isinstance(engines_payload, dict):
            for name, entry in engines_payload.items():
                if isinstance(entry, dict):
                    yield entry.get("name", name), entry
                else:
                    yield name, entry


    def entry_enabled(entry):
        if not isinstance(entry, dict):
            return None
        if "disabled" in entry:
            return not bool(entry["disabled"])
        if "enabled" in entry:
            return bool(entry["enabled"])
        return True


    def key_engine_enabled(config_payload):
        states = dict(KEY_ENGINE_DEFAULTS)
        if not isinstance(config_payload, dict):
            return states

        for name, entry in iter_engine_entries(config_payload.get("engines", [])):
            if not isinstance(name, str):
                continue
            normalized = name.lower()
            if normalized not in states:
                continue
            enabled = entry_enabled(entry)
            if enabled is not None:
                states[normalized] = enabled

        return states


    def result_domain(result):
        url = result.get("url")
        if not isinstance(url, str):
            return None

        hostname = urllib.parse.urlparse(url).hostname
        if not hostname:
            return None

        hostname = hostname.lower().rstrip(".")
        if hostname.startswith("www."):
            hostname = hostname[4:]
        return hostname


    def result_engines(result):
        value = result.get("engines")
        if value is None:
            value = result.get("engine")

        if isinstance(value, str):
            return [value]
        if isinstance(value, list):
            return [engine for engine in value if isinstance(engine, str)]
        return []


    def sanitize_unresponsive(raw_unresponsive):
        names = set()
        if not isinstance(raw_unresponsive, list):
            return []

        for entry in raw_unresponsive:
            name = None
            if isinstance(entry, str):
                name = entry
            elif isinstance(entry, (list, tuple)) and entry and isinstance(entry[0], str):
                name = entry[0]
            elif isinstance(entry, dict):
                name = entry.get("engine") or entry.get("name")

            if isinstance(name, str):
                names.add(name)

        return sorted(names)


    def summarize_search(label, payload, elapsed, error):
        summary = {
            "label": label,
            "ok": error is None,
            "elapsed_seconds": elapsed,
            "result_count": 0,
            "top_domains": [],
            "engine_counts": {},
            "unresponsive_engines": [],
        }
        if error is not None:
            summary["error"] = error
            return summary

        results = payload.get("results", []) if isinstance(payload, dict) else []
        if not isinstance(results, list):
            results = []

        domains = collections.Counter()
        engines = collections.Counter()
        for result in results:
            if not isinstance(result, dict):
                continue

            domain = result_domain(result)
            if domain is not None:
                domains[domain] += 1

            for engine in result_engines(result):
                engines[engine] += 1

        summary["result_count"] = len(results)
        summary["top_domains"] = [
            domain for domain, _count in domains.most_common(TOP_DOMAIN_LIMIT)
        ]
        summary["engine_counts"] = dict(sorted(engines.items()))
        summary["unresponsive_engines"] = sanitize_unresponsive(
            payload.get("unresponsive_engines", []) if isinstance(payload, dict) else []
        )
        return summary


    def write_health(health):
        os.makedirs(STATE_DIR, exist_ok=True)
        encoded = json.dumps(health, indent=2, sort_keys=True) + "\n"
        fd, tmp_path = tempfile.mkstemp(
            prefix=".health.",
            suffix=".json",
            dir=STATE_DIR,
            text=True,
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp_path, 0o640)
            os.replace(tmp_path, OUTPUT_PATH)
        except Exception:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass
            raise


    def main():
        config_payload, config_elapsed, config_error = fetch_json("/config")
        health = {
            "timestamp": utc_now(),
            "config": {
                "ok": config_error is None,
                "elapsed_seconds": config_elapsed,
            },
            "key_engine_enabled": key_engine_enabled(config_payload),
            "queries": [],
            "unresponsive_engines": [],
        }
        if config_error is not None:
            health["config"]["error"] = config_error

        all_unresponsive = set()
        for index, query in enumerate(QUERY_CORPUS):
            if index > 0:
                time.sleep(QUERY_DELAY_SECONDS)

            payload, elapsed, error = fetch_json(
                "/search",
                {
                    "q": query["query"],
                    "format": "json",
                    "language": "all",
                },
            )
            summary = summarize_search(query["label"], payload, elapsed, error)
            all_unresponsive.update(summary["unresponsive_engines"])
            health["queries"].append(summary)

        health["unresponsive_engines"] = sorted(all_unresponsive)
        write_health(health)


    if __name__ == "__main__":
        main()
  '';
in
{
  services = {
    nginx = {
      tailscaleAuth = {
        enable = true;
        virtualHosts = [ domain ];
      };

      virtualHosts.${domain} = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/".proxyPass = "http://127.0.0.1:${toString config.services.searx.settings.server.port}";
      };
    };

    searx = {
      enable = true;
      environmentFile = secretFile;

      settings = {
        server = {
          port = 8888;
          bind_address = "127.0.0.1";
          secret_key = "$SEARX_SECRET_KEY";
        };

        search.formats = [
          "html"
          "json"
        ];

        # Kagi-inspired public seed list; keep engine tuning conservative because scraper health varies.
        engines = [
          # Use the Brave Search API directly in clients; SearXNG's scraper is noisy here.
          {
            name = "brave";
            engine = "brave";
            shortcut = "br";
            categories = [
              "general"
              "web"
            ];
            brave_category = "search";
            paging = true;
            time_range_support = true;
            disabled = true;
          }
          {
            name = "duckduckgo";
            weight = 1.2;
          }
          {
            name = "google";
            weight = 1.05;
          }
          {
            name = "startpage";
            disabled = true;
            weight = 1.05;
          }
          {
            name = "mojeek";
            disabled = true;
            weight = 0.9;
          }
          {
            name = "wiby";
            disabled = true;
            weight = 0.35;
          }
          {
            name = "wikipedia";
            weight = 1.25;
          }
          {
            name = "github";
            weight = 1.15;
          }
          {
            name = "mdn";
            weight = 1.25;
          }
          {
            name = "stackoverflow";
            weight = 1.15;
          }
          {
            name = "superuser";
            weight = 1.0;
          }
          {
            name = "arch linux wiki";
            weight = 1.1;
          }
          {
            name = "nixos wiki";
            disabled = false;
            weight = 1.15;
          }
        ];

        # Kagi-inspired seed list; hostnames is the main ranking knob.
        hostnames = {
          high_priority = [
            "(.*\\.)?wikipedia\\.org$"
            "(.*\\.)?github\\.com$"
            "(.*\\.)?nixos\\.org$"
            "(.*\\.)?nix\\.dev$"
            "(.*\\.)?nix-community\\.github\\.io$"
            "(.*\\.)?docs\\.searxng\\.org$"
            "(.*\\.)?docs\\.openwebui\\.com$"
            "(.*\\.)?docs\\.firecrawl\\.dev$"
            "(.*\\.)?developer\\.mozilla\\.org$"
            "(.*\\.)?docs\\.python\\.org$"
            "(.*\\.)?docs\\.rs$"
            "(.*\\.)?sqlite\\.org$"
            "(.*\\.)?pkg\\.go\\.dev$"
            "(.*\\.)?wiki\\.nixos\\.org$"
            "(.*\\.)?discourse\\.nixos\\.org$"
            "(.*\\.)?wiki\\.archlinux\\.org$"
            "(.*\\.)?users\\.rust-lang\\.org$"
            "(.*\\.)?stackoverflow\\.com$"
            "(.*\\.)?superuser\\.com$"
          ];

          low_priority = [
            "(.*\\.)?reddit\\.com$"
            "(.*\\.)?medium\\.com$"
            "(.*\\.)?quora\\.com$"
            "(.*\\.)?geeksforgeeks\\.org$"
            "(.*\\.)?tutorialspoint\\.com$"
            "(.*\\.)?w3schools\\.com$"
            "(.*\\.)?dev\\.to$"
            "(.*\\.)?hashnode\\.dev$"
            "(.*\\.)?iditect\\.com$"
            "(.*\\.)?slingacademy\\.com$"
            "(.*\\.)?youtube\\.com$"
          ];

          remove = [
            "(.*\\.)?pinterest\\..*$"
            "(.*\\.)?tiktok\\.com$"
            "(.*\\.)?readspike\\.com$"
            "(.*\\.)?koshka\\.love$"
          ];
        };
      };
    };

    homer.entries = [
      {
        name = "SearXNG";
        subtitle = "Search";
        url = "https://${domain}";
        logo = "/assets/icons/searxng.svg";
        group = "productivity";
      }
    ];
  };

  # Generate a fresh SearXNG secret at boot; CSRF tokens are session-scoped,
  # so there is no need to persist this across restarts.
  systemd = {
    services = {
      searx-gen-secret = {
        description = "Generate SearXNG secret key";
        wantedBy = [ "searx-init.service" ];
        before = [ "searx-init.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "searx-gen-secret" ''
            printf 'SEARX_SECRET_KEY=%s\n' "$(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${secretFile}
            chmod 400 ${secretFile}
          '';
        };
      };

      searx-health = {
        description = "Low-rate SearXNG health monitor";
        after = [ "searx.service" ];
        wants = [ "searx.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.python3}/bin/python3 ${searxHealthScript}";
          DynamicUser = true;
          StateDirectory = "searx-health";
          UMask = "0027";

          CapabilityBoundingSet = "";
          IPAddressAllow = [ "127.0.0.1/32" ];
          IPAddressDeny = [ "any" ];
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProcSubset = "pid";
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProtectSystem = "strict";
          RemoveIPC = true;
          RestrictAddressFamilies = [ "AF_INET" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
            "~@resources"
          ];
        };
      };
    };

    timers.searx-health = {
      description = "Run low-rate SearXNG health monitor";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 00/4:00:00";
        RandomizedDelaySec = "45min";
        Persistent = true;
        Unit = "searx-health.service";
      };
    };
  };
}
