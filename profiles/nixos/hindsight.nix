{
  self,
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "hindsight.vaz.ovh";
  port = 8889;
  postgresqlDatabase = "hindsight";
  postgresqlUser = "hindsight";
  databaseUrl = "postgresql://${postgresqlUser}@/${postgresqlDatabase}?host=/run/postgresql";
  postgresqlUnit = "postgresql.service";
  postgresqlSetupUnit = "postgresql-setup.service";
  vectorInitScript = pkgs.writeShellScript "hindsight-vector-init" ''
    set -euo pipefail

    ${config.services.postgresql.finalPackage}/bin/psql -v ON_ERROR_STOP=1 -d ${lib.escapeShellArg postgresqlDatabase} <<'SQL'
    CREATE EXTENSION IF NOT EXISTS vector;
    SQL
  '';
in
{
  imports = [
    "${self}/modules/nixos/hindsight.nix"
  ];
  age.secrets = {
    hindsightApiToken = {
      file = "${self}/secrets/hindsightApiToken.age";
      mode = "0400";
    };
  };

  services = {
    hindsight = {
      enable = true;
      bindAddress = "127.0.0.1";
      inherit port;
      stateDir = "/var/lib/hindsight";
      inherit databaseUrl;
      # The Strata engine (Qwen3.8-Flash-Next IQ3_S) on tiberius,
      # OpenAI-compatible on the tailnet. The endpoint needs no key (the
      # module's placeholder is what it gets); thinking is disabled for every
      # call because the served template defaults to it; the engine generates
      # one request at a time, so client concurrency is pinned to 1 and the
      # read timeout is raised above the 120 s default for cold prefills
      # (1050-1160 tok/s) and 28-30 tok/s decode.  The 2026-10-11 on-box A/B
      # of the refresh job kept this lane as the default - 283 s against the
      # 27B vLLM lane's 67-617 s, with a richer page - so the 27B lane stays
      # installed as the parked fast/interactive lane (hosts/tiberius.nix has
      # the full note).
      # The tailnet policy allows pius outbound TCP to tiberius:8080 (verified
      # 2026-10-09 from pius: TCP connect and /health both succeed).
      llmProvider = "openai";
      llmModel = "qwen3.8-flash-next-iq3_s";
      llmBaseUrl = "http://tiberius:8080/v1";
      embeddingsProvider = "onnx";
      tenantApiKeyFile = config.age.secrets.hindsightApiToken.path;
      tenantExtension = "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension";
      environment = {
        HINDSIGHT_API_WORKER_ID = "pius-hindsight";
        HINDSIGHT_API_LLM_TRACE_ENABLED = "false";
        HINDSIGHT_API_STORE_DOCUMENT_TEXT = "false";
        HINDSIGHT_API_EMBEDDINGS_ONNX_MODEL_ID = "intfloat/multilingual-e5-small";
        HINDSIGHT_API_EMBEDDINGS_ONNX_DIMENSIONS = "384";
        HINDSIGHT_API_RERANKER_PROVIDER = "rrf";
        HINDSIGHT_API_REFLECT_LLM_PROVIDER = "openai";
        HINDSIGHT_API_REFLECT_LLM_MODEL = "qwen3.8-flash-next-iq3_s";
        HINDSIGHT_API_LLM_EXTRA_BODY = ''{"chat_template_kwargs":{"enable_thinking":false}}'';
        HINDSIGHT_API_LLM_TIMEOUT = "600";
        HINDSIGHT_API_LLM_MAX_CONCURRENT = "1";
        # A mental-model refresh runs the REFLECT pipeline, not consolidation,
        # and the reflect default is 300 s for the whole operation - tool-call
        # iterations over a 9.5-28K-token prompt that also queue behind other
        # jobs on the single-slot engine.  Every refresh since 2026-07-03 died
        # at that cap ("Task exceeded the 300s wall-clock limit for
        # 'refresh_mental_model'"); reproduced 2026-10-11 on strata and on the
        # 27B lane alike (attempt=1/4, cancelled at 300 s with the model still
        # working).  Hindsight's retain/consolidation defaults are 3600/7200 s
        # for the same reason; 1800 keeps the per-call LLM timeout (600 s) as
        # the operative ceiling while letting a refresh finish (measured: the
        # refresh then completes in 283 s on strata, 67-617 s on the 27B).
        HINDSIGHT_API_REFLECT_WALL_TIMEOUT = "1800";
      };
      user = "hindsight";
      group = "hindsight";
      package = pkgs.hindsight.override {
        withLocalOnnx = true;
      };
    };

    postgresql = {
      enable = true;
      extensions = postgresqlPackages: [
        postgresqlPackages.pgvector
      ];
      ensureDatabases = [ postgresqlDatabase ];
      ensureUsers = [
        {
          name = postgresqlUser;
          ensureDBOwnership = true;
        }
      ];
    };

    nginx = {
      # Everything behind this vhost -- the API, but also /metrics, /docs,
      # /openapi.json and /mcp -- must be reachable only from the tailnet: the
      # host firewall opens 80/443 on every interface, so this nginx gate
      # (tailscale.nginx-auth) is what keeps non-tailnet clients out.
      tailscaleAuth = {
        enable = true;
        virtualHosts = [ domain ];
      };

      virtualHosts.${domain} = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          proxyWebsockets = true;
          # The app's own LLM timeout is 600s; nginx must not cut a
          # synchronous retain/reflect short before that.
          extraConfig = ''
            proxy_read_timeout 600s;
          '';
        };
      };
    };

    homer.entries = [
      {
        name = "Hindsight";
        subtitle = "Memory API";
        url = "https://${domain}";
        group = "ai";
      }
    ];
  };

  users.groups.hindsight.gid = lib.mkDefault 1000;
  users.users.hindsight = {
    isSystemUser = true;
    uid = lib.mkDefault 1000;
    group = "hindsight";
    home = "/var/lib/hindsight";
    createHome = false;
  };

  systemd.services = {
    hindsight = {
      after = [ "hindsight-vector-init.service" ];
      wants = [ "hindsight-vector-init.service" ];
      requires = [ "hindsight-vector-init.service" ];
    };

    hindsight-vector-init = {
      description = "Initialize Hindsight PostgreSQL vector extension";
      after = [
        postgresqlUnit
        postgresqlSetupUnit
      ];
      requires = [
        postgresqlUnit
        postgresqlSetupUnit
      ];
      before = [ "hindsight.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        ExecStart = vectorInitScript;
        RemainAfterExit = true;
      };
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/hindsight";
      user = "hindsight";
      group = "hindsight";
      mode = "0700";
    }
    {
      directory = "/var/cache/hindsight";
      user = "hindsight";
      group = "hindsight";
      mode = "0700";
    }
  ];
}
