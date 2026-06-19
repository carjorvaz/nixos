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
    deepseekApiKey.file = "${self}/secrets/deepseek-api-key.age";
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
      llmProvider = "deepseek";
      llmModel = "deepseek-v4-flash";
      llmApiKeyFile = config.age.secrets.deepseekApiKey.path;
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

    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        proxyWebsockets = true;
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
