{
  lib,
  pkgs,
}:

let
  firecrawlModule = ../modules/nixos/firecrawl.nix;

  mkFirecrawlConfig =
    firecrawlConfig:
    lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        firecrawlModule
        {
          nixpkgs.pkgs = pkgs;
          services.firecrawl = {
            enable = true;
            package = pkgs.firecrawl;
          }
          // firecrawlConfig;
          system.stateVersion = "25.11";
        }
      ];
    };

  minimalConfig = mkFirecrawlConfig { };

  unsafeBindEval = builtins.tryEval (
    (mkFirecrawlConfig {
      bindAddress = "0.0.0.0";
      useDbAuthentication = false;
    }).config.system.build.toplevel.drvPath
  );
in
{
  firecrawl-module-generic-quality = pkgs.runCommand "firecrawl-module-generic-quality" { } ''
    forbidden='tailscaleAuth|services\.homer|homer\.|vaz\.ovh|useACMEHost'

    if grep -nE "$forbidden" ${firecrawlModule}; then
      echo "Firecrawl module still contains private reverse-proxy/dashboard concerns." >&2
      echo "Keep those in profiles/nixos/firecrawl.nix, not in the generic module." >&2
      exit 1
    fi

    touch $out
  '';

  firecrawl-unsafe-bind-rejected = pkgs.runCommand "firecrawl-unsafe-bind-rejected" { } ''
    if [ "${lib.boolToString unsafeBindEval.success}" = true ]; then
      echo "Firecrawl must reject unauthenticated non-loopback API binds." >&2
      exit 1
    fi

    touch $out
  '';

  firecrawl-module-eval = pkgs.runCommand "firecrawl-module-eval" { } ''
    cat > $out <<'EOF'
    api=${minimalConfig.config.systemd.services.firecrawl-api.serviceConfig.ExecStart}
    worker=${minimalConfig.config.systemd.services.firecrawl-worker.serviceConfig.ExecStart}
    extractWorker=${minimalConfig.config.systemd.services.firecrawl-extract-worker.serviceConfig.ExecStart}
    redis=${lib.boolToString minimalConfig.config.services.redis.servers.firecrawl.enable}
    EOF
  '';

  firecrawl-nixos-smoke = pkgs.testers.runNixOSTest {
    name = "firecrawl-nixos-smoke";

    nodes.machine = {
      imports = [ firecrawlModule ];

      virtualisation = {
        cores = 2;
        memorySize = 4096;
      };

      services.firecrawl = {
        enable = true;
        package = pkgs.firecrawl;
        logLevel = "warn";
        environment = {
          # Firecrawl normally rejects private/loopback scrape targets. This is
          # test-only so the VM can scrape its own deterministic HTTP fixture
          # without reaching the public network.
          ALLOW_LOCAL_WEBHOOKS = true;
          TEST_SUITE_SELF_HOSTED = true;
        };
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        pkgs.python3
      ];

      system.stateVersion = "25.11";
    };

    testScript = ''
      def wait_for_firecrawl_unit(unit):
          machine.wait_for_unit(unit, timeout=240)

      def wait_for_loopback_port(port, timeout=180):
          machine.wait_until_succeeds(f"ss -ltn | grep -F '127.0.0.1:{port}'", timeout=timeout)

      try:
          for unit in [
              "postgresql.service",
              "rabbitmq.service",
              "redis-firecrawl.service",
              "firecrawl-api.service",
              "firecrawl-worker.service",
              "firecrawl-extract-worker.service",
          ]:
              wait_for_firecrawl_unit(unit)

          wait_for_loopback_port(3002)
          wait_for_loopback_port(3004, timeout=60)
          wait_for_loopback_port(3005, timeout=60)

          machine.succeed("mkdir -p /tmp/firecrawl-site")
          machine.succeed("printf '%s\\n' '<!doctype html><title>Firecrawl test</title><main>Firecrawl NixOS test fixture</main>' > /tmp/firecrawl-site/index.html")
          machine.succeed("systemd-run --unit=firecrawl-fixture-http --collect --property=WorkingDirectory=/tmp/firecrawl-site ${pkgs.python3}/bin/python3 -m http.server 8080 --bind 127.0.0.1")
          machine.wait_for_unit("firecrawl-fixture-http.service", timeout=30)
          wait_for_loopback_port(8080, timeout=30)

          machine.succeed("curl -fsS --max-time 60 -H 'Content-Type: application/json' -d '{\"url\":\"http://127.0.0.1:8080/\",\"formats\":[\"markdown\"],\"onlyMainContent\":true}' http://127.0.0.1:3002/v1/scrape | tee /tmp/firecrawl-scrape.json")
          machine.succeed("jq -e '.success == true and (.data.markdown | contains(\"Firecrawl NixOS test fixture\"))' /tmp/firecrawl-scrape.json")
      except Exception:
          print(machine.succeed("systemctl --no-pager --full status postgresql.service rabbitmq.service redis-firecrawl.service firecrawl-api.service firecrawl-worker.service firecrawl-extract-worker.service || true"))
          print(machine.succeed("journalctl --no-pager -u firecrawl-api.service -u firecrawl-worker.service -u firecrawl-extract-worker.service -n 300 || true"))
          print(machine.succeed("ss -ltnp || true"))
          raise
    '';
  };
}
