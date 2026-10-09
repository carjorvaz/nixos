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
      # Strata (Qwen3.8-Flash-Next) on tiberius, OpenAI-compatible on the
      # tailnet. The endpoint needs no key (the module's placeholder is what it
      # gets); thinking is disabled for every call because the served template
      # defaults to it; the engine generates one request at a time, so client
      # concurrency is pinned to 1 and the read timeout is raised above the
      # 120 s default for cold prefills and ~20 tok/s decode.
      # NOTE: the tailnet policy must allow pius outbound TCP to tiberius:8080
      # (source-side tagging currently blocks it).
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

  users.groups.hindsight.gid = 1000;
  users.users.hindsight = {
    isSystemUser = true;
    uid = 1000;
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
